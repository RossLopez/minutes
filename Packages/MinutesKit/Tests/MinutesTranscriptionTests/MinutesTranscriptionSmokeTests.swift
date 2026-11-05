// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesTranscription
import Testing

@Test func `module is linked`() {
    #expect(MinutesTranscriptionInfo.name == "MinutesTranscription")
}
