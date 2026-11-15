// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the demo library says. Every person, place and plan in it is made up.
extension DemoLibrary {
    static func websiteLaunch(startedAt: Date) -> Meeting {
        Meeting(
            title: "Website launch check-in",
            startedAt: startedAt,
            names: ["speaker-1": "Priya", "speaker-2": "Marcus", "speaker-3": "Elena"],
            lines: lines(websiteScript),
            summary: """
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
            """,
            notes: """
            pricing page waiting on plan names
            launch on a friday?? risky
            soft launch the day before
            redirects for old blog links

            """,
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

    static let websiteScript = """
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
