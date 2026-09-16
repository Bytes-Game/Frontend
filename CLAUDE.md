# Working with this repo

## How to talk to me

**Always explain in easy, plain language.** This is the most important rule here
and it applies to every single answer, not just the ones that look complicated.

- No jargon. If a technical term is unavoidable, say what it means in the same
  breath, in normal words.
- Short sentences. Short paragraphs.
- Lead with the plain-English answer. The code details come after, and only if
  they are actually needed.
- Explain things the way you would to a smart person who does not already know
  this codebase.
- Do not hide behind class names, method names, and log lines. Say what is
  actually happening and why the user would notice it.

Bad: "The `pauseAllExcept` future never resolves because the platform channel
reply is dropped when the codec is reclaimed."

Good: "The app waits for the old video to stop before starting the new one.
Sometimes the old video never reports back that it stopped, so the app waits
forever and the new video never starts."

Same rule for commit messages, PR descriptions, and code comments: plain and
direct.

## When I send you a log

**Read the whole thing. All of it.**

Not the lines you expect to matter. Not a grep for the words you already have
a theory about. The whole file, and a count of what is actually in it.

This is not a style preference, it is the difference between finding the bug
and not finding it. A real example from this repo:

A log was 43,000 lines. The app's own diagnostic summary was 13 of them. Those
13 lines were read, for several rounds, and produced several fixes that each
made sense and none of which fixed the problem — because the cause was in the
other 42,987 lines, which nobody had counted.

What those lines said, once counted:

    57 video decoders    2,661 frames rendered    0 frames dropped

A decoder only drops frames when it cannot keep up. Zero dropped means it was
never behind — it was always WAITING for video that had not arrived. Every fix
so far had been about which file to download. None of them could have helped.

So, before forming any theory:

- Count what kinds of lines are in the file, and how many of each. The biggest
  group is often not the one you were looking at.
- Read the error lines, even the ones from Android or the decoder that look
  like noise. Three thousand of them is not noise.
- Look for the numbers that CONTRADICT the theory, not the ones that fit it.

And never answer "I cannot find it" or "I have no fix I can defend". If the
evidence is not in the log, add a log line and say what the next run should
show. Silent failure paths are bugs in their own right — `catch (_) { return; }`
hid a whole page failing for two rounds of diagnosis.
