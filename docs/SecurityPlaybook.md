# Security Assessment Playbook

This playbook captures the continuous security assessment workflow for the LI.FI contracts. Use it when onboarding new facets, updating pricing logic, or reviewing production incidents.

## 1) Systematic Attack-Surface Enumeration
- Inventory every externally callable function (facets, periphery, registry contracts) and classify by: funds movement, oracle read/write, state settlement, and external calls.
- Tag functions that: (a) pull prices, (b) mint/burn shares, (c) perform swaps, (d) bridge assets, (e) update global indices.
- Build and maintain a dependency graph of price feeds, adapters/routers, and strategies to expose weak links and shared dependencies.

## 2) Invariant-First Security Modeling
Define invariants per subsystem (vaults, pools, lending markets, perpetuals), for example:
- Total assets ~= total liabilities (within fees).
- Share price monotonicity under deposits/withdrawals.
- Borrowable value <= collateral value * LTV.
- No single transaction can reduce pool value below defined bounds without a corresponding asset transfer.

Encode invariants in Foundry invariant tests or fuzzers (Echidna/Medusa) and track them in the test suite.

## 3) Adversarial Input Generation
- For each external call path, inject adversarial parameters: malicious swapData, custom router targets, zero-liquidity pools.
- Simulate extreme price jumps, flash-loan scale liquidity, and repeated calls.
- Test reentrancy via callbacks, hooks, or token fallback behaviors.
- Use differential testing against a simplified reference model to detect non-conservation of value.

## 4) Oracle Hardening Playbook
- Enforce minimum liquidity and time-weighted windows.
- Use medianization across multiple sources/oracles.
- Deny single-block or low-liquidity spot prices for collateralization or share pricing.
- Add runtime guards that reject price updates beyond defined deviation thresholds.

## 5) Reentrancy and State-Ordering Checks
- Prohibit external calls before state finalization for all financial updates.
- Apply checks-effects-interactions and reentrancy guards consistently.
- Instrument runtime assertions on nested calls (reentrancy depth, state diffs) in tests.

## 6) Arithmetic Precision Audits
- Identify division/multiplication points and check for rounding bias.
- Use fixed-point math libraries consistently; avoid mixed precision.
- Test for overflow/underflow and rounding accumulation across repeated operations.

## 7) Automated On-chain Monitoring
Create real-time monitors for:
- Sudden supply increases, abnormal mint/burn spikes.
- Large deviation between oracle price and DEX TWAP.
- Asset outflows without corresponding inflows.
- Unusual reentrancy patterns (same contract entered multiple times).

Trigger circuit breakers (e.g., pausing facets) when invariants are violated.

## Continuous Context, Memory, and Self-Evaluation
- Record every assessment outcome in the existing `audit/auditLog.json` file under the `audits` map (include `auditCompletedOn`, `auditedBy`, `auditorGitHandle`, `auditReportPath`, `auditCommitHash`, plus links to relevant contracts, commits, and test evidence).
- Maintain an attack-surface map and invariant registry alongside the review notes so future audits inherit the latest context.
- After every incident or release, run a post-review to update invariants, monitoring thresholds, and enumeration coverage.
