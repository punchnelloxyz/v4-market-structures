# 17 market structures for Uniswap v4

Seventeen small contracts. Each one takes a real mechanic of a real market and
turns it into a price.

A pool installs up to **four** of them, picked when it opens and frozen for good.
On every swap the hook asks each one what it wants to charge, adds them up, and
that is the fee for that trade.

## The one rule

**A structure can only make a trade more expensive. It cannot refuse one.**

It hands back a number and nothing else. It cannot stop a sell, cap a wallet,
pause a pool or block an address, because there is no way for it to say no. That
is not a policy we promise to keep, it is the shape of the interface: `quote()`
returns a fee. Nothing it returns can prevent a trade.

It also cannot read or write storage, move a token, or call back into the pool.
It gets told the size, the reserves and the price, and it answers.

## What each one does

### Physical — how the thing behaves in the world. It costs money to keep, it goes off, it breaks.

**Breaker** — The market-wide circuit breaker, with the halt replaced by a price.

**Carry** — Storage costs money, and somebody has been paying it since block one.

**Impact** — A big order moves the price against you, and the merchant prices the move rather than the order.

**Outage** — Things break without warning, and the price finds out before anybody does.

**Spoilage** — Goods left on the shelf go off, and the shelf remembers how long it has been.

**TickRegime** — A price that cannot move by a tick has not moved, and quoting it anyway is the thing exchanges charge for.

### Supply — how much of it there is, and what the last unit costs when there is nearly none left.

**Borrow** — What the last available share costs is not what the first one cost.

**Lockup** — The date the insiders are allowed to sell is on the calendar from day one.

**OddLot** — Breaking a lot to fill a small order costs the warehouse something, and exchanges used to charge for it by name.

**Quota** — A producer decides how much leaves the ground this month, and the price of wanting more than that is the whole history of commodity markets.

### Term — time. Curves, calendars, and dates everyone can see coming.

**Cross** — A real exchange does not open by trading. It opens by crossing, and the first minutes of a session are nothing like the middle of one.

**ExDiv** — On one specific morning a quarter, the price is lower and nothing has gone wrong.

**TermStructure** — The shape of the curve, not the level of it, is what a carry market charges you for.

**Witching** — Four days a year, everything expires at once, and the whole market knows it.

### Delivery — what happens when more people hold a claim than can actually be delivered.

**Delivery** — What happens when more people hold a claim on the warehouse than the warehouse can actually deliver.

**Uptick** — Once a market has fallen far enough, pressing it down further costs money.

### Reference — the one that does nothing, on purpose.

**Null** — A trait that expresses nothing about the underlying, on purpose.

## Live on Robinhood Chain 4663

Deployed 11 September 2026. Each answers `describe()` with its family and name.

| Structure | Address |
|---|---|
| Borrow | `0xd13b939b4bc751788ec03d3a138ef8c613835132` |
| Breaker | `0xf47d98ce7824afed933091b7805759b84fcb8399` |
| Carry | `0xed55fdbc08b0877da5e48aa4dc91f6fe2b738d17` |
| Cross | `0x1c74057bea5680822e7b7896ef2acd5958a32913` |
| Delivery | `0xe86df24c359d385fbb8b7c8949293caf82d00b33` |
| ExDiv | `0x9b9c6b2d6bf08d07adccedf99f2cf753499dd340` |
| Impact | `0xe01c3cadc9b411f4e623978120a58bdb8f194c07` |
| Lockup | `0xb9993494f7e6436ecaa2a86099d8cf9fe3ed80db` |
| Null | `0xc1e83ac8dc1ca85fcf9a4e241de10abcda18bc05` |
| OddLot | `0x45fad25712c25d6752a09da221f8fa61aea24b31` |
| Outage | `0x7c42bac1b9cebdf445c4556efa3aaf66f5bc2a8b` |
| Quota | `0xe0f8cef50c6680171586a32fde2d822bd5c14cb8` |
| Spoilage | `0x9b9e681ada856e79c8b4744de2fda64d6b435c39` |
| TermStructure | `0x0337c0271d4c648ed677bbabc46f55a64959a940` |
| TickRegime | `0x1059d8cf2e5d142eab38b2ec229f9a5f8d7309a8` |
| Uptick | `0xa8fbc93dd0e495fddf8007d456327f3134bfb2c1` |
| Witching | `0xe9846a87aee4d53a41f60ac84a13239c893e05f3` |

## Files

- `src/` — the seventeen structures plus `TraitBase.sol`, the shared helpers.
- `interfaces/ITrait.sol` — the whole interface. It is short, and it is where the
  rule above actually lives.

## Licence

MIT.
