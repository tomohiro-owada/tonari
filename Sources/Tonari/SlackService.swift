import Foundation

enum SlackServiceError: LocalizedError {
    case invalidResponse
    case apiError(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Slack API のレスポンスが不正"
        case .apiError(let e): return "Slack API エラー: \(e)"
        case .http(let s):     return "HTTP \(s)"
        }
    }
}

struct SlackAuthTestResult {
    let team: String
    let user: String
    let teamId: String
    let userId: String
    let url: String
}

struct SlackMessage {
    let user: String
    let text: String
    let ts: String
}

struct SlackUnreadIM {
    let id: String
    let userId: String
    let lastRead: String?
    let mentionCount: Int
}

struct SlackUnreadChannel {
    let id: String
    let name: String?
    let lastRead: String?
    let mentionCount: Int
}

struct SlackClientCounts {
    let ims: [SlackUnreadIM]
    let channels: [SlackUnreadChannel]
}

struct SlackThreadReply {
    let channelId: String
    let channelName: String?    // resolved if available
    let threadTs: String
    let parentSnippet: String   // first ~120 chars of the parent (root) message
    let replyUserId: String
    let replyUserName: String   // resolved
    let replyText: String
    let replyTs: String
}

struct SlackUnreadSummary {
    struct DM {
        let userName: String
        let texts: [String]
    }
    struct Mention {
        let channelName: String
        let userName: String
        let text: String
    }
    struct ChannelDigest {
        struct Msg {
            let user: String
            let text: String
            let mentionsMe: Bool
        }
        let name: String
        let messages: [Msg]
    }
    let dms: [DM]
    let mentions: [Mention]
    let channels: [ChannelDigest]
    let totalUnreadChannels: Int
}

/// Talks to slack.com/api/* using an xoxc client token + d cookie pair.
/// Auth pattern: token in form body, `d` cookie in Cookie header.
final class SlackService {
    private let baseURL = URL(string: "https://slack.com/api/")!
    private let creds: SlackCredentials

    init(creds: SlackCredentials) {
        self.creds = creds
    }

    // MARK: - Thread replies (private endpoint subscriptions.thread.getView)

    /// Fetch unread replies in threads the user is subscribed to.
    /// Uses the private `subscriptions.thread.getView` endpoint that powers
    /// Slack desktop's "Threads" tab. Response schema is undocumented — we
    /// parse defensively and log the raw envelope for inspection if empty.
    func fetchUnreadThreadReplies(limit: Int = 50) async throws -> [SlackThreadReply] {
        let json = try await callJSON(method: "subscriptions.thread.getView", params: [
            "limit": "\(limit)",
            "org_wide_aware": "true"
        ])
        guard (json["ok"] as? Bool) == true else {
            throw SlackServiceError.apiError(json["error"] as? String ?? "unknown")
        }

        // Schema discovery: look for an array of thread items under several
        // likely keys. Whichever exists, use it.
        let threadsArr: [[String: Any]] =
            (json["threads"] as? [[String: Any]]) ??
            (json["thread_view"] as? [[String: Any]]) ??
            (json["items"] as? [[String: Any]]) ??
            []

        if threadsArr.isEmpty {
            // Log envelope keys so we can adapt if Slack changed the shape
            NSLog("Tonari: subscriptions.thread.getView returned no threads array. Top-level keys: %@",
                  Array(json.keys).joined(separator: ","))
            return []
        }

        var nameCache: [String: String] = [:]
        var channelCache: [String: String] = [:]
        var out: [SlackThreadReply] = []

        for t in threadsArr {
            // Try a few common field names
            let channelId =
                (t["channel"] as? String) ??
                (t["channel_id"] as? String) ??
                ""
            let threadTs =
                (t["thread_ts"] as? String) ??
                (t["root_ts"] as? String) ??
                ""
            // Parent / root message snippet
            let parentSnippet: String = {
                if let root = t["root_msg"] as? [String: Any],
                   let text = root["text"] as? String { return String(text.prefix(140)) }
                if let root = t["root_message"] as? [String: Any],
                   let text = root["text"] as? String { return String(text.prefix(140)) }
                if let text = t["root_text"] as? String { return String(text.prefix(140)) }
                return ""
            }()
            // Unread replies — could be under several names
            let replies: [[String: Any]] =
                (t["unread_replies"] as? [[String: Any]]) ??
                (t["new_replies"] as? [[String: Any]]) ??
                (t["replies"] as? [[String: Any]]) ??
                (t["messages"] as? [[String: Any]]) ??
                []

            // Resolve channel name lazily
            var chName: String? = channelCache[channelId]
            if chName == nil && !channelId.isEmpty {
                if let n = try? await conversationsInfo(channelId: channelId) {
                    chName = n
                    channelCache[channelId] = n
                }
            }

            for r in replies {
                let userId = (r["user"] as? String) ?? ""
                let text = (r["text"] as? String) ?? ""
                let ts = (r["ts"] as? String) ?? ""
                if text.isEmpty { continue }
                var userName = nameCache[userId]
                if userName == nil && !userId.isEmpty {
                    if let n = try? await usersInfo(userId: userId) {
                        userName = n
                        nameCache[userId] = n
                    }
                }
                out.append(SlackThreadReply(
                    channelId: channelId,
                    channelName: chName,
                    threadTs: threadTs,
                    parentSnippet: parentSnippet,
                    replyUserId: userId,
                    replyUserName: userName ?? userId,
                    replyText: String(text.prefix(240)),
                    replyTs: ts
                ))
            }
        }
        return out
    }

    func formatThreadReplies(_ replies: [SlackThreadReply]) -> String {
        if replies.isEmpty {
            return "未読のスレッドリプライはありません。"
        }
        // Group by thread
        var grouped: [String: [SlackThreadReply]] = [:]
        var order: [String] = []
        for r in replies {
            let key = "\(r.channelId)::\(r.threadTs)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(r)
        }
        var out = "── 未読スレッドリプライ (\(replies.count) 件 / \(order.count) スレッド) ──\n"
        for key in order {
            guard let rs = grouped[key], let first = rs.first else { continue }
            let chLabel = first.channelName.map { "#\($0)" } ?? first.channelId
            out += "\n[\(chLabel)] スレッド: 「\(first.parentSnippet)」\n"
            for r in rs {
                out += "  ・\(r.replyUserName): 「\(r.replyText)」\n"
            }
        }
        return out
    }

    // MARK: - High-level

    /// One-shot unread fetcher: client.counts → conversations.history per
    /// unread DM/mentioned-channel → users.info for name resolution.
    func fetchUnreadSummary(
        myUserId: String,
        maxChannels: Int = 8,
        maxPerChannel: Int = 3
    ) async throws -> SlackUnreadSummary {
        let counts = try await clientCounts()
        var nameCache: [String: String] = [:]
        var dms: [SlackUnreadSummary.DM] = []
        var mentions: [SlackUnreadSummary.Mention] = []
        var channels: [SlackUnreadSummary.ChannelDigest] = []

        func name(_ id: String) async -> String {
            if let n = nameCache[id] { return n }
            if let info = try? await usersInfo(userId: id) {
                nameCache[id] = info
                return info
            }
            nameCache[id] = id
            return id
        }

        // DMs (all)
        for im in counts.ims {
            let other = await name(im.userId)
            let msgs = (try? await conversationsHistory(
                channelId: im.id, oldest: im.lastRead, limit: maxPerChannel
            )) ?? []
            let texts = msgs.map { String($0.text.prefix(200)) }
            if !texts.isEmpty {
                dms.append(SlackUnreadSummary.DM(userName: other, texts: texts))
            }
        }

        // Channels with unreads — fetch top N (mention_count first, then rest)
        let prioritized = counts.channels.sorted { (a, b) in
            if a.mentionCount != b.mentionCount {
                return a.mentionCount > b.mentionCount
            }
            return (a.name ?? a.id) < (b.name ?? b.id)
        }
        for ch in prioritized.prefix(maxChannels) {
            let chName: String
            if let n = ch.name {
                chName = n
            } else if let n = try? await conversationsInfo(channelId: ch.id) {
                chName = n
            } else {
                chName = ch.id
            }
            let msgs = (try? await conversationsHistory(
                channelId: ch.id, oldest: ch.lastRead, limit: maxPerChannel
            )) ?? []
            var digest: [SlackUnreadSummary.ChannelDigest.Msg] = []
            for msg in msgs {
                let user = await name(msg.user)
                let mentionsMe = msg.text.contains("<@\(myUserId)>")
                digest.append(.init(
                    user: user,
                    text: String(msg.text.prefix(220)),
                    mentionsMe: mentionsMe
                ))
                if mentionsMe {
                    mentions.append(.init(
                        channelName: chName,
                        userName: user,
                        text: String(msg.text.prefix(240))
                    ))
                }
            }
            if !digest.isEmpty {
                channels.append(.init(name: chName, messages: digest))
            }
        }

        return SlackUnreadSummary(
            dms: dms,
            mentions: mentions,
            channels: channels,
            totalUnreadChannels: counts.channels.count
        )
    }

    func format(_ s: SlackUnreadSummary) -> String {
        var out = ""
        if !s.dms.isEmpty {
            out += "── 未読 DM (\(s.dms.count) 名から) ──\n"
            for dm in s.dms {
                out += "・\(dm.userName) (\(dm.texts.count)件)\n"
                for t in dm.texts.prefix(3) {
                    out += "  「\(t)」\n"
                }
            }
        }
        if !s.mentions.isEmpty {
            if !out.isEmpty { out += "\n" }
            out += "── 未読メンション (\(s.mentions.count) 件) ──\n"
            for m in s.mentions {
                out += "・#\(m.channelName) で \(m.userName) より\n  「\(m.text)」\n"
            }
        }
        if !s.channels.isEmpty {
            if !out.isEmpty { out += "\n" }
            out += "── 未読チャンネル (\(s.channels.count)/\(s.totalUnreadChannels)) ──\n"
            for ch in s.channels {
                out += "・#\(ch.name)\n"
                for m in ch.messages {
                    let mark = m.mentionsMe ? "📣 " : "   "
                    out += "  \(mark)\(m.user): 「\(m.text)」\n"
                }
            }
        }
        let omitted = s.totalUnreadChannels - s.channels.count
        if omitted > 0 {
            if !out.isEmpty { out += "\n" }
            out += "(残り \(omitted) 個の未読チャンネルは省略しています)\n"
        }
        if out.isEmpty {
            return "未読の DM・メンション・チャンネルはありません。"
        }
        return out
    }

    // MARK: - auth.test

    func authTest() async throws -> SlackAuthTestResult {
        let json = try await callJSON(method: "auth.test")
        guard (json["ok"] as? Bool) == true else {
            throw SlackServiceError.apiError(json["error"] as? String ?? "unknown")
        }
        return SlackAuthTestResult(
            team: json["team"] as? String ?? "",
            user: json["user"] as? String ?? "",
            teamId: json["team_id"] as? String ?? "",
            userId: json["user_id"] as? String ?? "",
            url: json["url"] as? String ?? ""
        )
    }

    // MARK: - API methods

    func clientCounts() async throws -> SlackClientCounts {
        let json = try await callJSON(method: "client.counts", params: [
            "thread_counts_by_channel": "true",
            "org_wide_aware": "true",
            "include_file_channels": "false"
        ])
        guard (json["ok"] as? Bool) == true else {
            throw SlackServiceError.apiError(json["error"] as? String ?? "unknown")
        }
        let ims = ((json["ims"] as? [[String: Any]]) ?? []).compactMap { d -> SlackUnreadIM? in
            guard let id = d["id"] as? String else { return nil }
            let hasUnreads = (d["has_unreads"] as? Bool) ?? false
            let mc = (d["mention_count"] as? Int) ?? 0
            guard hasUnreads || mc > 0 else { return nil }
            return SlackUnreadIM(
                id: id,
                userId: (d["user_id"] as? String) ?? (d["user"] as? String) ?? "",
                lastRead: d["last_read"] as? String,
                mentionCount: mc
            )
        }
        let channels = ((json["channels"] as? [[String: Any]]) ?? []).compactMap { d -> SlackUnreadChannel? in
            guard let id = d["id"] as? String else { return nil }
            let hasUnreads = (d["has_unreads"] as? Bool) ?? false
            let mc = (d["mention_count"] as? Int) ?? 0
            guard hasUnreads || mc > 0 else { return nil }
            return SlackUnreadChannel(
                id: id,
                name: d["name"] as? String,
                lastRead: d["last_read"] as? String,
                mentionCount: mc
            )
        }
        return SlackClientCounts(ims: ims, channels: channels)
    }

    func conversationsHistory(channelId: String, oldest: String? = nil, limit: Int = 5) async throws -> [SlackMessage] {
        var params: [String: String] = ["channel": channelId, "limit": "\(limit)"]
        if let oldest { params["oldest"] = oldest }
        let json = try await callJSON(method: "conversations.history", params: params)
        guard (json["ok"] as? Bool) == true else {
            throw SlackServiceError.apiError(json["error"] as? String ?? "unknown")
        }
        let arr = (json["messages"] as? [[String: Any]]) ?? []
        let msgs = arr.compactMap { d -> SlackMessage? in
            guard let user = (d["user"] as? String) ?? (d["bot_id"] as? String),
                  let text = d["text"] as? String,
                  let ts = d["ts"] as? String else { return nil }
            return SlackMessage(user: user, text: text, ts: ts)
        }
        return msgs.reversed()  // Slack returns newest first
    }

    func usersInfo(userId: String) async throws -> String {
        let json = try await callJSON(method: "users.info", params: ["user": userId])
        guard (json["ok"] as? Bool) == true else {
            throw SlackServiceError.apiError(json["error"] as? String ?? "unknown")
        }
        let user = (json["user"] as? [String: Any]) ?? [:]
        let profile = (user["profile"] as? [String: Any]) ?? [:]
        let display = (profile["display_name"] as? String) ?? ""
        let real = (profile["real_name"] as? String) ?? ""
        let name = (user["name"] as? String) ?? userId
        if !display.isEmpty { return display }
        if !real.isEmpty { return real }
        return name
    }

    func conversationsInfo(channelId: String) async throws -> String {
        let json = try await callJSON(method: "conversations.info", params: ["channel": channelId])
        guard (json["ok"] as? Bool) == true else {
            throw SlackServiceError.apiError(json["error"] as? String ?? "unknown")
        }
        let channel = (json["channel"] as? [String: Any]) ?? [:]
        return (channel["name"] as? String) ?? channelId
    }

    // MARK: - Internal

    private func callJSON(method: String, params: [String: String] = [:]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(method)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("d=\(creds.cookieD)", forHTTPHeaderField: "Cookie")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8",
                     forHTTPHeaderField: "Content-Type")

        var form = params
        form["token"] = creds.token
        let body = form.map { k, v in
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return "\(k)=\(ev)"
        }.joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SlackServiceError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackServiceError.invalidResponse
        }
        return json
    }
}
