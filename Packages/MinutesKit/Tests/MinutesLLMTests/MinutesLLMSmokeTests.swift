// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import Testing

@Test func `module is linked`() {
    #expect(MinutesLLMInfo.name == "MinutesLLM")
}
