# Transcription engine comparison

Nov 6, 2026. Measured on one MacBook Pro with an M5 Pro and 24 GB of RAM, macOS 27.0.1, for Milestone 3.

## Decision

**Apple's `SpeechTranscriber` is the default, with Parakeet TDT v2 as an optional download in Settings. WhisperKit is left out.** Ross chose this on Nov 6, 2026, after reading the recommendation below. The default needs no third-party model download, and anyone who wants better accuracy on their terms can switch.

## Recommendation

**I recommended Parakeet TDT v2 through FluidAudio as the default, with Apple's `SpeechTranscriber` as the switch in Settings, leaving WhisperKit out.**

- **Parakeet v2** with strict vocabulary settings got your terms right 49 times out of 52, with no false terms in a 30-minute meeting that never says them. It also had the lowest error rate on your voice and the second lowest on the meeting.
- **Apple** needs no dependency or download, so it's a good alternative. But it got only 30 of 52 terms, and its vocabulary setting changed nothing.
- **WhisperKit** did well on your voice, but it was last on the meeting, about 3 to 5 times slower than the others and a 1.5 GB download. Its best term score needed 2.2 GB of memory for 30 minutes of audio. A second engine dependency isn't worth that.

**One condition:** Minutes must transcribe long meetings in pieces of about 30 minutes. As a single long file, Parakeet's vocabulary step produced false terms and used more memory. See [Long meetings](#long-meetings).

## Results

"Meeting" is word errors on the AMI meeting. "Your voice" is word errors on the script you read. "Terms" counts correct terms out of 52, after the fixed replacement of listed variants. "False terms" counts your terms appearing in the AMI meeting, which never says any of them.

| Engine and setup | Meeting | Your voice | Terms | False terms | Speed | Peak memory, 30 min |
| --- | --- | --- | --- | --- | --- | --- |
| **Parakeet v2, strict vocabulary** | 11.8%* | **5.2%** | **49** | **0** | 107× | 420 MB |
| Parakeet v2, no vocabulary | 11.8% | 6.3% | 43 | 0 | 179× | 213 MB |
| Parakeet v2, middle setting | 11.8%* | 4.9% | 52 | 5 | 107× | 428 MB |
| Parakeet v2, library defaults | 11.8%* | Not scored | 52 | 18 | 107× | 427 MB |
| Parakeet Ultra, no vocabulary | **10.6%** | 7.8% | 43 | 0 | 200× | 165 MB |
| Parakeet Ultra, strict vocabulary | 10.6%* | 6.2% | 46 | 2 | 115× | 353 MB |
| Apple `SpeechTranscriber` | 13.1% | 12.5% | 30 | 0 | 115× | About 130 MB, in a system service |
| Apple `DictationTranscriber`, with vocabulary | Not run | 18.4%† | 32 | Not run | 46× | Not measured |
| Whisper turbo, no chunking | 15.0% | 6.2% | 43 | 0 | 35× | 393 MB |
| Whisper turbo, chunked at speech pauses (VAD) | 15.8–16.6% | 5.7% | 49 | 0 | 32× | 2.2 GB |

\* Before the vocabulary step, which only changes the terms it replaces. The scorer reads word timings, which that step doesn't update.

† Without vocabulary, the only setup scored for word errors. It scored 16 of 52 terms without vocabulary.

Other measurements, without the vocabulary step:

| | Apple | Parakeet v2 | Whisper turbo |
| --- | --- | --- | --- |
| Download | Managed by macOS, size not shown | About 450 MB, plus 99 MB for vocabulary | 1.5 GB |
| First use, including any download | No wait seen | 46 s | 139 s, plus 63 s on the first transcription |
| Later starts | Under 1 s | Under 1 s | 2–4 s |
| Typical word timing offset (median) | 90 ms | 60 ms | 90 ms |
| Slowest 10% of words | 400 ms or more | 180 ms or more | About 500 ms or more |
| Words of 5+ letters heard correctly | 87.4% | 90.5% | 86–88% |
| Words invented on digital silence or quiet noise, 5 min each | 0 | 0 | 0 |

**Your quiet minute:** after the last line of the script, no engine produced any words.

**Gaps between speech in the meeting:** on 2.3 minutes of them, all three heard much the same few words, so that's probably speech the transcript doesn't cover. Whisper added a few more.

## What stood out

- **Apple ignores vocabulary.** `SpeechTranscriber`'s output was word-for-word the same with `contextualStrings` set or not, whether given at creation or through `setContext`. `DictationTranscriber` does respond (from 16 to 32 terms), but its overall accuracy is the worst here.
- **A Whisper prompt made terms worse.** Prompting with the term list dropped Whisper from 48 to 46 as heard, and it lost words: 563 instead of 615.
- **Parakeet's vocabulary step needs strict settings.** At its defaults it hit every term, but rewrote real words, including "titanium" into Tanium, and put 18 false terms into the unrelated meeting.
- **Strict settings still miss some.** Parakeet v2 missed one each of Nessus, POAM and SIEM. It also misheard "seam", with or without vocabulary.
- **Whisper's chunking changes its results a lot.** With VAD it got 48 terms as heard, and without it 42. VAD also used 2.2 GB, and it added 2 extra terms to the script while losing the ordinary words "poem" and "seam". Its very first run heard only about half of a 60-second clip, and I didn't find out why.
- **Whisper's errors are mostly skipped words.** Its wrong-word count is about the same as Parakeet's. Ignoring repeated words only closes part of the gap: 14.1–14.5% against Parakeet v2's 10.8%.
- **Parakeet Ultra** beat v2 on the meeting but lost on your voice and your terms. It's the same model family as the multi-language v3, so it could matter if other languages ever arrive.

## Long meetings

Every setup I ran on a 4-hour file finished it, but Parakeet's memory grew with length, and so did its false terms.

| Setup on 4 hours | Speed | Peak memory |
| --- | --- | --- |
| Apple | 113× | About 150 MB, in a system service |
| Parakeet v2, no vocabulary | 166× | 1.3 GB |
| Parakeet v2, strict vocabulary | 69× | 3.3 GB |
| Parakeet Ultra, no vocabulary | 198× | 832 MB |
| Parakeet Ultra, middle vocabulary | 72× | 2.3 GB |
| Whisper, no chunking | 35× | 2.3 GB |

Whisper with VAD wasn't run at this length, because it already needed 2.2 GB for 30 minutes.

**False terms grow with file length on the same audio:**

| Same meeting, strict vocabulary | False terms |
| --- | --- |
| 30 minutes, three separate copies, one of them AAC | 0, 0, 0 |
| 2 hours as one file | 8 |
| 4 hours as one file | 18 |

AAC isn't the cause. Each 30-minute run stayed near 420 MB. So the app transcribes in pieces of about 30 minutes, cut at the quietest moment near each limit.

**Measured with the app's engine on the same files, using pieces:**

| | As one file | In pieces |
| --- | --- | --- |
| Peak memory, 4 hours | 3.3 GB | 797 MB |
| False terms, 2 hours | 8 | 3 |
| False terms, 4 hours | 18 | 5 |
| Speed, 4 hours | 69× | 70× |

Every remaining false term is the same mistake: the meeting really says "titanium" twice per copy, and 5 of those 16 mentions became "Tanium". That's the nearest sound-alike on the list, and whether it flips depends on where the audio frames fall. So pieces cut the false terms but don't end them, and an ordinary word that sounds like a term can still get replaced.

The app's engines also match the comparison on 30 minutes and on your voice: Parakeet got 49 of 52 terms, 5.2% and 11.8% word errors, and Apple got 30 of 52, 12.5% and 13.1%.

## Limits of these numbers

- **Tuning:** I picked the strict settings after seeing these results, on the same script. The false-term test on the meeting is independent, but the 49 of 52 may flatter it. Your real vocabulary will show more.
- **One voice:** your voice on AirPods Pro 3, reading a list I drafted. The term count (24) also affects FluidAudio's size-based settings.
- **One meeting:** about 4,000 words, recorded on headsets and mixed to one track, with people talking over each other. Real system audio could differ.
- **One Mac:** I have no 8 GB Mac to test on.
- **Memory:** Core ML and Apple's speech service do work outside the process. The table shows the process's own peak, except Apple, which shows its service's growth. Other apps were running throughout.
- **Permission:** Apple's engine shows no permission prompt, from a command-line tool or in the signed app.

## What the app would take on

**[FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.2**, Apache 2.0, pinned to an exact version. It's compatible with GPL v3. It's a young project with frequent releases, so the engine stays behind our protocol.

| Part | License | Notes |
| --- | --- | --- |
| FluidAudio | Apache 2.0 | No other Swift packages |
| fastcluster, compiled in | BSD 2-Clause | Used by its diarizer |
| A small lexicon resource | eSpeak NG (GPL-3.0-or-later) and FrequencyWords (CC BY-SA 4.0) data | 1 MB, for its text-to-speech. **Not in the app** with traits off, as checked in the build |
| NemoTextProcessing, a prebuilt Rust library | Apache 2.0 | Downloaded during package resolve (87 MB), but **not linked** with traits off |
| Parakeet TDT v2 and CTC models | CC BY 4.0 | Downloaded when you ask, needs attribution in `THIRD_PARTY_NOTICES.md` |

Two things to handle:
- **Model folder:** the vocabulary step reads its tokenizer from FluidAudio's default folder, not the one we choose. Models belong in `~/Minutes/Models`, so I'll need to pass tokens in directly or work around it.
- **Word timings:** the vocabulary step returns corrected text without updating word timings, which click-to-play needs. I'll have to map replacements back onto the words.

It also gives Milestone 4 a head start: its diarizer exposes 256-dimension speaker embeddings, which suits Speaker memory. I haven't tested them.

## How it was tested

- **Meeting:** AMI meeting IS1009c, 30.3 minutes, headset mix, with its human transcript. Filler sounds are removed from both sides before scoring, and numbers and a few spellings are normalized.
- **Script:** 24 terms, said 52 times in about 4 minutes, plus ordinary look-alikes such as "titanium" and "poem". You read it on AirPods Pro 3, then stayed quiet for about a minute.
- **Variants:** written before any engine heard the script.
- **Versions:** argmax-oss-swift 1.1.1, model `large-v3-v20240930_turbo`; FluidAudio 0.18.2; the macOS 27.0.1 speech model.
- **Settings:** strict is `cbw: 0, minSimilarity: 0.7`, and middle is `cbw: 2, minSimilarity: 0.6`.

The tool and scoring are in `Spikes/TranscriptionSpike/`. The script, your recording and the AMI audio aren't in the repo. CI doesn't build that package, and the app doesn't link it.

```bash
cd Spikes/TranscriptionSpike && swift build -c release
```

### Credit

Uses the [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) (CC BY 4.0), by the AMI Consortium. Audio was cut, repeated and re-encoded for these tests, and none of it is redistributed here.
