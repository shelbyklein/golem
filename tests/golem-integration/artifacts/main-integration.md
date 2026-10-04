# Main integration before Mac trial

Main was clean at b9b2ae4 after the user's go-ahead. Its Home, Command Center, terminal color, Sidechat, Restart Thread and Studio conversion changes were merged into Golem before installation.

Integration reconciles signed product scopes with Home/Command Center icons, forwards Restart Thread to the single-writer daemon with durable async receipts, and preserves Sidechat/converted Studio metadata, secret scope, companion grouping and fork scope. Parent deletion retains the existing orphan behavior.

Verified: optimized Chatterbox and Golem builds, genuine signed Golem role, headless core/RPC/companion/policy suites, migration/restore, isolated LaunchAgent lifecycle, native Sidechat/Studio/Command Center/Restart Thread interactions and both iPhone product simulator suites. Native regression harnesses now share an isolated test library. Persistence fixtures read saved records directly rather than creating a second concurrent writer.

The original full CPU fixture remains prior to main integration; no claim of a newly repeated battery/RSS/wakeup or real workload result is made. Physical iPad window/rotation, VoiceOver and real APNs acceptance remains open. The user approved a backed-up development Mac switch with automation paused, not release or issue closure.
