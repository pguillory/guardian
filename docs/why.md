# Why Guardian

Logging taught us to record everything once and decide later what to ask. When you put
in logs, you don't know exactly what questions you'll need to ask or where the answers
will come from. You have some idea, but logging is cheap, so you're generous. It's no
fun to need logging you don't have, and to add it and reanalyze after an incident is
already underway.

Enforcement is similar. You don't know exactly what you'll need to enforce, or when, or
where. So make hooking in enforcement cheap, do it generously, and decide later what to
enforce against. Then during a problem you aren't adding the hook, building and
redeploying.

Go one step further and make every log a potential enforcement hook. Describe every
request with the fields that matter, wire up a few generic responses once, such as
block, slow down or serve from cache, and every future fix can be a rule written when
you need it rather than a feature someone had to build in advance. Logging, analysis,
decisions and enforcement become one end-to-end system, which keeps the loop from
noticing a problem to acting on it tight. That's how you win against spam and get
through incidents faster. Guardian is an attempt at building that system.

## An example

Say a script starts hammering a search endpoint that was built for occasional human use.
Each search is expensive for the database, and soon the whole product slows down. Your
analytics show which endpoint suddenly got slow. What you don't have is a way to block
just that endpoint, or better, just that endpoint for that IP, and get everything else
back on its feet.

Doing that would take two product features: a runtime kill switch for endpoints and an
IP blocklist. Each is reasonable, and neither is something anyone builds ahead of time
for a situation that comes up rarely. The script's author may not even be malicious.
This kind of problem isn't only about attackers.

There's a long tail of situations like this, and it's effectively endless. The responses
they need are few and generic.

## Seeing isn't stopping

Most services can see a problem long before they can do anything about it. Analytics
will tell you which endpoint got slow or which accounts are acting in unison. Stopping
just that traffic usually means writing and shipping code, in the middle of the
incident.

Parts of this have been solved, one domain at a time. Most fraud products let you write
your own rules on top of the vendor's score, test them on recent history, and enforce
them inline. What they rarely give you is a single place where you can freely explore
your own raw events, spot a pattern, and turn exactly what you found into an enforced
rule, in any part of your product rather than just payments. Exploration usually lives
in one tool and enforcement in another, and the exploration side is usually the weaker
one.

## The loop

Many of the problems an online service faces come down to one loop:

1. Observe what's happening in your system.
2. Tell what you want from what you don't.
3. Adapt the system to stop only what you don't want.

Logs and analytics handle the first two well. The third is usually left as an exercise
for the reader. The value is in tying them together and running the loop as fast as you
can. You need to be able to look at real traffic, try a heuristic and a few variants
against past events to see what each would have caught, put the best one in place, and
keep watching.

Speed matters more than it used to, because the people working against you are fast now
too. In 2026, an operator directed hundreds of AI agents against PaperCut print servers
and, according to GreyNoise, went from an empty workspace to remote code execution in
under four hours, reaching 395 organizations
([BleepingComputer](https://bleepingcomputer.com/news/security/ai-powered-attack-exploited-papercut-flaws-to-hack-395-organizations)).
The same year, about 1,200 OpenAI evaluation agents running with safeguards disabled
went beyond what their operators intended, got past bot filters by moving to a less
protected server, and treated access limits "as an obstacle rather than a boundary"
([Hugging Face](https://huggingface.co/blog/security-incident-july-2026),
[SiliconANGLE](https://siliconangle.com/2026/09/24/researchers-link-more-cyberattacks-to-openai-agent-swarm/)).
Those were mostly infrastructure intrusions, not the application abuse this doc is
about, but they show the pace. Whatever you put in place gets probed, so fixed rules
decay.

## Why it takes judgment

There's no spec you can buy for acceptable use. Is 50 messages an hour too many? It
depends on who's sending them, to whom, and what your product is for. That's a judgment,
often a product judgment, and only your application has the context to make it.

The judgment is about behavior, not identity. More and more legitimate traffic comes
from agents acting for real users, so "is this a bot?" says less every year about
whether you want what it's doing. The OpenAI case makes the same point from the other
side: a well-known, legitimate operator's agents still misbehaved.

Often the clearest signal isn't one account but a population: a group of accounts that
sign up in the same minute, act in unison, or all do something slightly odd in the same
way. You only see that by looking across your traffic.

## Why rules and not just a model

A natural question is why not label the data and train a model. Labels arrive late, or
don't exist at all for a pattern you've never seen. A model freezes yesterday's
judgment, and it gets probed like anything else. A score explains nothing to the person
affected or to management, and it can't cheaply answer "what if we drew the line here
instead?" Swarms are population patterns that per-request scores tend to miss.

Models are evidence, and rules are policy. A model's score can be one input a rule
weighs, alongside everything else you know.

## Respond in proportion, and say why

The response should fit the behavior. The range runs from allow, through slow down,
challenge and flag for review, to revoke and block. Most surprising behavior calls for
slowing down, not shutting down. Some decisions need to happen inline, in milliseconds.
Others are better made after the fact, once a pattern is clear, so you also need to be
able to act later by flagging or revoking the accounts involved. Only your application
can say what each response means in your product.

People deserve to know why something happened to them, and different people need
different answers:

- The person affected asks "why was I blocked from logging in?" Tell them which policy
  they hit, not every heuristic behind it.
- Management asks "why have we been blocking so much lately?" Show the trends.
- Whoever improves the policy asks "how do we block more of the bad and less of the
  good?" That takes the history of decisions and the traffic behind them.
- For your own investigations, keep the full detail of what was decided and why.

Publish your limits. Abusers will find them by probing anyway, and legitimate heavy
users need to know them so they can stay under them. Limits should also be easy to
create, analyze and re-tune, because the first version is rarely right.

## Where it applies

- Per-user AI and API spend
- What a user's agent is allowed to do on their behalf
- SMS and one-time-password pumping
- Free trial, promo and referral abuse
- Scalping by swarms at drop time
- Shedding load by value during an incident
- Outbound email reputation
- Noisy neighbors

The approach fits best where a wrong call is cheap and reversible (slow down, step up,
demote, hold), where the pattern changes faster than you can ship code, and where the
difference between what you want and what you don't can be said in a sentence. It's the
wrong tool for exact billing or quotas, or for compliance audit records. It also isn't
protection against volumetric denial-of-service attacks; it complements edge protection
rather than replacing it.

## What it costs

Making every log a potential enforcement hook only works if the check costs almost
nothing. Every request waits on it, so its latency and availability become part of
yours. That's the hard part of this approach, and it's where most of the engineering has
to go: the system has to be extremely fast and extremely reliable, or nobody will be
willing to hook it in generously. Getting that right is what makes the rest possible.

When the system can't be reached, your application has to decide what happens. Failing
open keeps the service available. Failing closed can be the right call for sensitive or
expensive operations. Different parts of the same application can choose differently.
