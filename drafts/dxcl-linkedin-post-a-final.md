# DXCL LinkedIn: Post A (DPDP) and Post B, final copy for 19 Nov 2026

Status: FINAL TEXT, NOT POSTED. Publish through Postroom or paste from your phone. Post A goes from your profile, then reshare from the DrishtiX page.

Changes from the 21 Oct draft (so you know what is different):
- "29 weeks from now" is now "25 weeks" (13 May 2027 is 175 days from 19 Nov).
- The link now points at the real page, /infomedia/dpdp-rules-the-clock-is-running/. The old draft linked to a slug that does not exist.
- The "29-week plan" claim is removed. The published post lists what to test, not a week-by-week plan.
- "The penalty table" now says "the biggest lines", because the Schedule has more entries than the four shown.
- Post B: [BOOKING_URL] is now https://dxcl.tech/contact/, the same call to action the blog uses.
- Checked 19 Nov: no amendment shortening the 18-month window has been notified, so 13 May 2027 still stands. Recheck the MeitY notice on the day you post.

---------------------------------------------------------------------
POST A (paste everything between the lines)
---------------------------------------------------------------------

"₹250 crore fine" is the line everyone quotes about India's data protection law.

Here's what the Act itself says. These are the biggest lines in the penalty Schedule of the DPDP Act, 2023:

→ Up to ₹250 crore: failing to take reasonable security safeguards to prevent a breach
→ Up to ₹200 crore: failing to notify the Board and affected users of a breach
→ Up to ₹200 crore: breaching the duties for children's data
→ Up to ₹50 crore: any other contravention

Three things founders miss:

1. These are ceilings. The Board sets the amount based on how serious the breach was, how long it lasted and what you did about it.

2. The biggest penalty isn't for being breached. It's for not having reasonable safeguards. If something goes wrong, you have to show what you had in place.

3. The duties switch on 13 May 2027, about 25 weeks from now. MeitY has floated shortening that window, so don't count on the full 25.

I wrote up what "reasonable safeguards" means under the DPDP Rules, and what to test before the deadline. Link in the first comment.

Not legal advice. If you want to know where your app stands, DM me.

#DPDP #DataProtection #Startups #CyberSecurity #India

FIRST COMMENT (post it once the blog page is live):

The full write-up: what switches on when, the breach-reporting rules and what to test before May 2027:
https://dxcl.tech/infomedia/dpdp-rules-the-clock-is-running/

---------------------------------------------------------------------
POST B (next, a day or two later)
---------------------------------------------------------------------

Checklist: what to test before the DPDP deadline (13 May 2027)

If you're a startup handling personal data, here's what I'd test before the deadline, in this order:

☐ Login and sessions: can one user see another user's data by changing an ID in the URL or API call?
☐ APIs: is every endpoint that returns personal data authenticated and rate-limited?
☐ Storage: is personal data encrypted at rest? Are backups encrypted too?
☐ Cloud: any public buckets, open admin panels or leaked keys in your repos?
☐ Access: who on your team (and which vendors) can reach production data? Is that logged?
☐ Logs: would you know who accessed what last month? The Rules expect a year of logs.
☐ AI features: can a prompt make your LLM reveal another user's data or its system instructions?
☐ Breach drill: could you write the detailed report to the Board within 72 hours?

Every box you can't tick is a finding. Finding it now is cheaper than finding it after a breach.

That's what a scoping call is for: we'll tell you which of these apply to your stack, and what a fixed-price test costs. DM me or book through the link in the comments.

#DPDP #VAPT #AppSec #AISecurity #Startups

FIRST COMMENT:

Book a scoping call: https://dxcl.tech/contact/
Background on the deadline: https://dxcl.tech/infomedia/dpdp-rules-the-clock-is-running/
