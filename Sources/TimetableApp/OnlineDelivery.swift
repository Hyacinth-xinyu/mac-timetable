import Foundation

/// 从每条安排自己的地点判断线上授课，避免同一原始段落中的线下安排被误标。
enum OnlineDelivery {
    static func isOnline(location: String) -> Bool {
        let text = (location.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? location)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !text.isEmpty else { return false }

        let explicitTerms = [
            "线上授课", "线上上课", "线上教学", "线上课程", "线上课堂", "线上学习",
            "在线授课", "在线上课", "在线教学", "在线课程", "在线课堂", "在线学习",
            "网络授课", "网络上课", "网络教学", "网络课程", "网络直播", "直播授课",
            "网课", "腾讯会议", "腾讯课堂", "飞书会议", "钉钉会议", "zoom会议", "teams会议"
        ]
        if explicitTerms.contains(where: { text.contains($0) }) { return true }

        // 单独标注“线上”或“在线”及其带括号、链接等补充信息的写法。
        // 不把“在线性代数实验室”等以相同文字开头的地点误判为线上。
        return text.range(of: #"^(线上|在线)(?:$|[\p{P}\p{S}])"#, options: .regularExpression) != nil
    }
}

extension Course {
    var isOnline: Bool { OnlineDelivery.isOnline(location: location) }
}
