import Foundation

/// Strips tracking parameters from a copied link.
///
/// Pure on purpose: no pasteboard, no settings. `ClipboardMonitor` decides
/// whether a copy is a bare link worth touching; this only answers what the
/// link looks like without its trackers, and is unit-tested on its own.
///
/// The query is edited as the *encoded* text it arrived as. Decoding and
/// re-encoding would respell parameters the cleaner never meant to touch —
/// `%20` becoming `+`, reserved characters gaining or losing escapes — and a
/// link that comes back spelled differently can point somewhere else.
enum URLCleaner {
    struct Result: Equatable {
        let url: String
        /// Parameter names that were taken out, in the order they appeared.
        let removed: [String]
    }

    /// Names removed on every host. Matched case-insensitively.
    static let globalNames: Set<String> = [
        // Ad-click identifiers.
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid",
        "twclid", "ttclid", "li_fat_id", "epik", "rdt_cid", "scclid", "irclickid",
        // Mail and marketing platforms.
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "hsctatracking", "mkt_tok", "vero_id",
        "vero_conv", "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid", "wickedid",
        "_branch_match_id", "_branch_referrer",
        // Analytics cross-domain linkers.
        "_gl", "_ga", "_kx", "ns_campaign", "ns_mchannel", "ns_source", "ns_linkname",
        "ns_fee", "igshid", "igsh"
    ]

    /// Prefixes removed on every host: `utm_source`, `utm_medium`, … and the
    /// Piwik/Matomo equivalents.
    static let globalPrefixes = ["utm_", "pk_", "mtm_"]

    /// Extra names per site, keyed by registrable domain. A host matches its key
    /// and every subdomain of it (`m.youtube.com` takes `youtube.com`'s rules).
    ///
    /// Only parameters that never change what the page shows. `t` on YouTube is
    /// a start time and `v` is the video, so neither is here; `si` and `pp` are
    /// share and ranking trackers.
    static let siteNames: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature", "embeds_referring_euri", "source_ve_path"],
        "youtu.be": ["si", "pp", "feature"],
        "spotify.com": ["si", "context", "nd", "dlsi"],
        "instagram.com": ["igsh", "igshid", "img_index"],
        "x.com": ["s", "t", "ref_src", "ref_url"],
        "twitter.com": ["s", "t", "ref_src", "ref_url"],
        "tiktok.com": ["_r", "_t", "is_from_webapp", "sender_device", "is_copy_url", "web_id"],
        "linkedin.com": ["trk", "trackingid", "lipi", "licu", "midtoken", "midsig", "trkemail", "eid"],
        "facebook.com": ["mibextid", "rdid", "share_url", "__tn__", "__cft__"],
        "reddit.com": ["share_id", "rdt", "$deep_link", "correlation_id", "ref_campaign", "ref_source"],
        "amazon.com": ["ref", "ref_", "pf_rd_r", "pf_rd_p", "pf_rd_s", "pf_rd_t", "pf_rd_i",
                       "pf_rd_m", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pd_rd_i", "content-id",
                       "crid", "sprefix", "qid", "sr", "dib", "dib_tag", "_encoding", "linkcode",
                       "linkid", "spla"],
        "google.com": ["ved", "ei", "sxsrf", "gs_lcp", "gs_lp", "sclient", "uact", "oq", "aqs",
                       "sourceid", "biw", "bih", "rlz", "sca_esv", "sca_upv", "iflsig", "gs_ssp"],
        "bing.com": ["form", "qs", "sp", "sc", "sk", "cvid", "ghsh", "ghacc", "ghpl"],
        "medium.com": ["source", "sk"],
        "substack.com": ["r", "s", "showwelcomeonshare", "triedredirect"],
        "aliexpress.com": ["spm", "scm", "pvid", "algo_pvid", "algo_exp_id", "aff_platform",
                           "aff_trace_key", "terminal_id", "afsmartredirect"],
        "ebay.com": ["_trkparms", "_trksid", "hash", "amdata", "mkevt", "mkcid", "mkrid",
                     "campid", "toolid", "customid"]
    ]

    /// Amazon serves the same store on many country domains.
    private static let amazonCountryDomains = [
        "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.in",
        "amazon.ca", "amazon.co.jp", "amazon.com.au", "amazon.com.mx", "amazon.com.br",
        "amazon.nl", "amazon.se", "amazon.pl", "amazon.ae", "amazon.sg"
    ]

    /// Returns the link with its trackers removed, or nil when `text` is not a
    /// single web link or there was nothing to remove.
    static func clean(_ text: String) -> Result? {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !link.contains(where: \.isWhitespace),
              let components = URLComponents(string: link),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              let query = components.percentEncodedQuery, !query.isEmpty
        else { return nil }

        let site = siteRules(for: host)
        var kept: [Substring] = []
        var removed: [String] = []

        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let rawName = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let name = (rawName.removingPercentEncoding ?? rawName).lowercased()
            if !name.isEmpty, isTracker(name, site: site) {
                removed.append(name)
            } else {
                kept.append(pair)
            }
        }

        guard !removed.isEmpty else { return nil }

        // Rebuilt by hand around the query rather than through URLComponents,
        // so everything outside it — fragment included — stays byte-for-byte.
        guard let queryRange = link.range(of: "?" + query) else { return nil }
        let head = link[..<queryRange.lowerBound]
        let tail = link[queryRange.upperBound...]
        let newQuery = kept.joined(separator: "&")
        let rebuilt = newQuery.isEmpty
            ? String(head) + tail
            : String(head) + "?" + newQuery + tail
        return Result(url: rebuilt, removed: removed)
    }

    private static func isTracker(_ name: String, site: Set<String>) -> Bool {
        if globalNames.contains(name) || site.contains(name) { return true }
        return globalPrefixes.contains { name.hasPrefix($0) }
    }

    private static func siteRules(for host: String) -> Set<String> {
        var rules: Set<String> = []
        for (domain, names) in siteNames where matches(host, domain) {
            rules.formUnion(names)
        }
        if amazonCountryDomains.contains(where: { matches(host, $0) }),
           let amazon = siteNames["amazon.com"] {
            rules.formUnion(amazon)
        }
        // Google runs on country domains too; its rules key on the label.
        if host == "google" || host.hasPrefix("google.") || host.contains(".google."),
           let google = siteNames["google.com"] {
            rules.formUnion(google)
        }
        return rules
    }

    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
