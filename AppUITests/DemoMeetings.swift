// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the demo library says. Every person, place and plan in it is made up.
extension DemoLibrary {
    /// The meeting in `App/Demo/DemoContent.swift`, which the app's demo mode plays too.
    static func websiteLaunch(startedAt: Date) -> Meeting {
        Meeting(
            title: DemoContent.title,
            startedAt: startedAt,
            names: Dictionary(uniqueKeysWithValues: DemoContent.names.map { code, name in
                ("speaker-" + code.dropFirst(), name)
            }),
            lines: lines(DemoContent.script),
            summary: DemoContent.summary,
            notes: DemoContent.notes,
        )
    }

    static func gardenClub(startedAt: Date) -> Meeting {
        Meeting(
            title: "Garden club spring plan",
            startedAt: startedAt,
            names: ["speaker-1": "Grace", "speaker-2": "Tomás"],
            lines: lines(gardenScript),
            summary: """
            ## Overview
            The club planned the spring: twice as many tomato seedlings for the plant sale, new compost \
            and beans for the library bed, and two Saturday workshops in April.

            ## Key points and decisions
            - Tomato seedlings sold out early last year, so the greenhouse will hold about 200 pots.
            - The library will pay for compost for the community bed once it has a quote.
            - **Decision:** The seed workshop is on April 5 and the pruning workshop on April 19.

            ## Action items
            - [ ] **Tomás:** Place the seed order on Friday.
            - [ ] **Tomás:** Get a compost quote from the farm on Mill Road.
            - [ ] **Grace:** Put both workshops on the club calendar and the noticeboard.
            """,
            notes: "",
        )
    }

    static func volunteerSchedule(startedAt: Date) -> Meeting {
        Meeting(
            title: "Volunteer schedule review",
            startedAt: startedAt,
            names: ["speaker-1": "Jordan"],
            lines: lines(volunteerScript),
            summary: """
            ## Overview
            Saturdays are covered, but Sundays need three more volunteers. The aim is a full schedule by \
            the end of the month.

            ## Key points and decisions
            - Sundays need six people and have three.
            - Some volunteers from last month's training said Sundays suit them.

            ## Action items
            - [ ] **Me:** Ask last month's new volunteers about Sundays.
            - [ ] **Jordan:** Update the shared schedule as people reply.
            - [ ] **Jordan:** Send the new key box code to everyone on the list.
            """,
            notes: "",
        )
    }

    /// "me" is the person recording, and "s1" is speaker-1.
    static func lines(_ script: String) -> [Line] {
        script.split(separator: "\n").map { line in
            let parts = line.split(separator: ": ", maxSplits: 1)
            let code = String(parts[0])
            return Line(code == "me" ? code : "speaker-" + code.dropFirst(), String(parts[1]))
        }
    }

    static let gardenScript = """
    s1: First on the list is the plant sale. Last year we ran out of tomato seedlings by ten.
    s2: We should start twice as many. There's room in the greenhouse for about two hundred pots.
    me: Two hundred sounds right. Can we get the seed order in this week?
    s2: I'll place it on Friday. Same supplier as last year, they were good.
    s1: Next is the community bed by the library. The soil there is tired.
    me: We could add compost in March and plant beans to put some life back into it.
    s1: I like that. The library said they'd pay for compost if we send them a quote.
    s2: I'll get a quote from the farm on Mill Road. They deliver.
    me: And the workshop days. Do we still want one on pruning?
    s1: Yes, and one on starting seeds, for families with kids. Saturdays work best.
    me: Let's pick April the fifth for seeds and April the nineteenth for pruning.
    s2: Works for me. I'll bring the spare trays.
    s1: I'll put both on the club calendar and the noticeboard.
    """

    static let volunteerScript = """
    s1: We have enough people for Saturday mornings, but Sundays are thin.
    me: How many do we need on a Sunday?
    s1: Four at the desk and two in the back. We have three right now.
    me: I can ask the new volunteers from last month's training. Some said Sundays suit them.
    s1: That would help. I'll update the shared schedule once people reply.
    me: Let's aim to have it full by the end of the month.
    s1: Also, the key box code changes next week. I'll send it to everyone on the list.
    me: Good, thanks. Let's check in again next Thursday.
    """
}
