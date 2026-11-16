// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
    import Foundation

    /// The made-up "Website launch check-in" meeting, for the README's screenshots and the demo
    /// video. Every person and plan in it is invented. The UI tests compile this file too, so the
    /// demo library and the app's demo mode say the same thing.
    ///
    /// With `MINUTES_DEMO=1`, the fake engines play this meeting: the level meters follow who's
    /// talking, and the transcript, voices, summary and chat answer come from here. Debug builds
    /// only.
    enum DemoContent {
        static var isOn: Bool {
            ProcessInfo.processInfo.environment["MINUTES_DEMO"] == "1"
        }

        /// How long the demo recording runs. The meeting is laid out over this, so the meters and
        /// the transcript agree.
        static let plannedSeconds = 45.0

        static let title = "Website launch check-in"

        /// By speaker code: `me` is the person recording, `s1` is the first other voice.
        static let names = ["s1": "Priya", "s2": "Marcus", "s3": "Elena"]

        static let script = """
        me: Okay, I think everyone's here. Let's go through where we are with the new website.
        s1: Design is done. The last pages went to Marcus on Monday, and Elena signed off the home page.
        s2: I've built all of them except the pricing page. That one needs the new plan names first.
        s3: The plan names are final as of this morning. I'll send them over right after this call.
        s2: Great. Then I can finish pricing by Wednesday.
        me: What about the contact form? Last week it was still sending to the old inbox.
        s2: Fixed. It goes to the shared support address now, and I tested it twice.
        s1: One thing I noticed on my phone. The menu covers the page title on small screens.
        s2: I saw that too. It's a quick fix, I'll do it with the pricing page.
        me: So are we still on track for launching on the twentieth?
        s3: I'd rather not launch on a Friday. If something breaks, nobody's around to fix it.
        s1: Agreed. Tuesday the twenty-fourth gives us the weekend for a last round of testing.
        me: Tuesday works for me. Marcus, does that change anything on your side?
        s2: No, it just gives me more room. Tuesday the twenty-fourth it is.
        me: Good, then that's decided. We launch on Tuesday the twenty-fourth.
        s3: I'll tell the newsletter list once the date is fixed. Should I write the announcement?
        s1: Please do. I can make two or three images for it.
        me: Who's checking the old links? A lot of people have the old blog addresses bookmarked.
        s2: I'll set up redirects for the blog. I need a list of the pages that get the most visits.
        me: I'll pull that from the analytics export and send it to you by Thursday.
        s3: Should we do a soft launch first, and share it with a few friends of the club?
        s1: I like that. Real people will find things we missed.
        me: Let's do it on Monday then, the day before. Elena, can you ask a few people?
        s3: Sure. I'll ask five or six people and collect what they find in one document.
        me: Perfect. Anything else before we wrap up?
        s2: Just that I'm away on Friday afternoon. Everything will be merged before then.
        me: Thanks, everyone. Same time next week, and I'll send the notes around.
        """

        static let summary = """
        ## Overview
        The team checked progress on the new website. Design is finished and most pages are built, \
        with the pricing page waiting on the final plan names. The launch moves from Friday the 20th \
        to Tuesday the 24th, with a soft launch to a few people the day before.

        ## Key points and decisions
        - Design is done, and Elena signed off the home page.
        - Marcus has built every page except pricing, which needs the new plan names.
        - The contact form now sends to the shared support address.
        - The menu covers the page title on small screens. Marcus will fix it with the pricing page.
        - **Decision:** The site launches on Tuesday the 24th instead of Friday the 20th.
        - **Decision:** A soft launch on Monday, shared with a few people, comes first.

        ## Action items
        - [ ] **Elena:** Send Marcus the final plan names today.
        - [ ] **Marcus:** Finish the pricing page and the small-screen menu fix by Wednesday.
        - [ ] **Me:** Send Marcus the most visited pages from analytics by Thursday.
        - [ ] **Marcus:** Set up redirects for the old blog addresses.
        - [ ] **Elena:** Write the launch announcement for the newsletter.
        - [ ] **Priya:** Make two or three images for the announcement.
        - [ ] **Elena:** Ask five or six people to try the soft launch, and collect what they find.
        """

        /// What the person recording types while the meeting goes on.
        static let notes = """
        pricing page waiting on plan names
        launch on a friday?? risky
        soft launch the day before
        redirects for old blog links

        """

        static let chatQuestion = "When is the website launching, and what happens before it?"

        static let chatAnswer = """
        The launch moved to **Tuesday the 24th**, because nobody wanted to launch on a Friday with no \
        one around to fix problems [1]. On the Monday before, there's a soft launch: Elena will ask five \
        or six people to try the site and collect what they find [2].

        Before then, Marcus finishes the pricing page and the small-screen menu fix by Wednesday [3].
        """

        struct Line {
            /// `me`, `s1`, `s2` and so on.
            let code: String
            let text: String
        }

        static var lines: [Line] {
            script.split(separator: "\n").map { line in
                let parts = line.split(separator: ": ", maxSplits: 1)
                return Line(code: String(parts[0]), text: String(parts[1]))
            }
        }

        struct TimedWord {
            let text: String
            let start: Double
            let end: Double
        }

        struct TimedLine {
            let code: String
            let start: Double
            let end: Double
            let words: [TimedWord]
        }

        /// The meeting spread over `seconds`, each line given time for its words, with a short
        /// pause between speakers and a moment of quiet at each end.
        static func layout(over seconds: Double = plannedSeconds) -> [TimedLine] {
            let lines = lines
            let lead = 1.0
            let pause = 0.3
            let wordCounts = lines.map { $0.text.split(separator: " ").count }
            let speaking = seconds - 2 * lead - pause * Double(lines.count - 1)
            let perWord = speaking / Double(wordCounts.reduce(0, +))
            var time = lead
            return zip(lines, wordCounts).map { line, count in
                let start = time
                let words = line.text.split(separator: " ").enumerated().map { index, word in
                    let wordStart = start + Double(index) * perWord
                    return TimedWord(text: String(word), start: wordStart, end: wordStart + perWord * 0.85)
                }
                time += Double(count) * perWord + pause
                return TimedLine(code: line.code, start: start, end: start + Double(count) * perWord, words: words)
            }
        }

        /// A made-up voice embedding for a speaker code, each pointing its own way, so a saved
        /// profile with the same one matches exactly and nothing else matches at all.
        static func voice(_ code: String) -> [Float] {
            let index = Int(code.dropFirst()) ?? 0
            return (0 ..< 4).map { $0 == index ? 1 : 0 }
        }

        /// Who's talking `seconds` into the demo recording, if anyone.
        static func speaker(at seconds: Double, in layout: [TimedLine]) -> String? {
            layout.first { $0.start <= seconds && seconds < $0.end }?.code
        }
    }
#endif
