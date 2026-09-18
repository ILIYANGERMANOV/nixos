# Replies

Read this in phase 6, when every thread is settled and the fixes are pushed.
Nothing here is loaded earlier, because nothing here is needed earlier.

Every reply posts from the user's own GitHub account, and **there is no AI
disclosure line anywhere**. The user reads and approves each one before it
posts, so these are their words. Do not add a banner, do not hedge about what a
model did or did not check, and do not write in a voice the user would not use.

Draft all of them, show them verbatim, and post nothing until the user
approves.

## The shape of a good reply

Three sentences at most. A reviewer is reading fifteen of these.

1. **What happened**, in the first few words. `Fixed in`, `Deferred`,
   `Leaving as is`. Never bury the outcome behind the reasoning.
2. **The one fact that settles it** - the commit, the trigger, the rule, the
   intent. Specific, not a category.
3. Nothing else. No thanks-for-the-review preamble, no apology, no "great
   catch", no offer to revisit unless it is true.

Never argue with the reviewer as a person, and never imply the comment was
stupid. The comment was a reasonable thing to raise; it just does not survive.

## FIX NOW

Name the commit and say what actually changed, in the reviewer's terms rather
than yours. The reviewer will click the SHA and read the diff, so the sentence
has to match what they will see.

> Fixed in `a1b2c3d` - the retry now only fires on 5xx, so a 401 falls straight
> through.

If the fix differs from what the reviewer proposed, say so plainly and in one
clause. Silently doing something else is how a resolved thread gets reopened.

> Fixed in `a1b2c3d`, though not quite as suggested - threading the attempt
> count through was enough, so the shared counter was not needed.

## PUSH BACK

This is the reply that has to be earned, and the one most likely to be wrong.
It always names **what was checked**. A push back that just asserts the comment
is wrong is worse than no reply at all.

Four flavors, by why it did not survive:

**Refuted.** Give the reason the trigger cannot happen, concretely.

> Leaving as is - the token is validated in `middleware.ts:22` before this
> handler runs, so `token` is never null here.

**No trigger.** Say what would change your mind. This keeps the door open
without committing to anything.

> Leaving as is for now - I could not find a case where this actually
> misbehaves. If you have an input that breaks it, reopen and I will fix it.

**Intent.** Quote the intent, briefly. The design was decided before the
review.

> This is deliberate - the retry is unbounded on purpose and callers set their
> own timeouts, so a cap here would override them.

**Net-negative.** Quote the house rule. This is the user's own decided rule,
not a preference, and saying which rule it is keeps it from reading as taste.

> True, but leaving it - there is one caller, and extracting a helper for it
> trades a clear thing for an indirection. Our engineering rules put simplicity
> ahead of reuse here.

**Already handled** is a push back too, and the friendliest one. It is a
statement of fact, not a disagreement, so write it that way.

> Already handled - this moved in `a1b2c3d` and the validation now happens
> upstream.

## FIX LATER

Agree first, then say why not here. A deferral that does not concede the point
reads as a polite refusal, which is worse than an honest refusal.

State the actual reason it is deferred - scope, risk, blast radius - not a
vague "separately". The reviewer is entitled to judge whether they agree with
the deferral.

> Agreed, and it is real. The fix has to thread the attempt count through every
> caller though, which is more than this PR should carry. Tracking it
> separately rather than widening the diff here.

Do not promise a ticket number in the reply. Where deferrals live is decided in
phase 7, after these have already posted, so a reply that names an issue that
does not exist yet is a broken promise in writing.

## The summary comment

One `gh pr comment` at the end, after every thread reply has posted. It does
two jobs: it gives the reviewer a single place to see the shape of the
response, and it is the **only** way top-level comments get answered, since
they have no thread to reply into.

Keep it to counts plus the things that need a sentence. Do not restate every
thread - the threads are right there.

> Went through the review.
>
> **Fixed (6)** - all in `a1b2c3d`. The retry path, the session comparison and
> four smaller ones.
>
> **Left as is (3)** - the rate limit and the helper extraction are deliberate,
> reasons in the threads. The null check is already handled upstream.
>
> **Deferred (2)** - the caller threading and the schema change. Both real,
> both bigger than this PR should carry.
>
> On your question about migration ordering: the new column is nullable and
> nothing reads it until the follow-up, so the order does not matter here.

The last paragraph is where a top-level comment gets its answer. Answer every
one of them. A top-level comment that goes unanswered looks ignored, and unlike
a thread there is nothing to resolve that would show otherwise.

## Failures

If a reply posts but the resolve call fails, say so and name the thread. Do not
retry silently, and never report a thread as resolved when it is not.

If the user edits a drafted reply, post what they wrote, not what you drafted.
