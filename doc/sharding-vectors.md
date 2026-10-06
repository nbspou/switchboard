# Sharding payloads (test vectors)

Hand-computed from the layouts on the wiki page "Switchboard Sharding",
little endian. Asserted by `test/vectors/sharding_vectors_test.dart`. For the
integrator: copy this section into the wiki page "Switchboard Test Vectors"
after "Naming service payloads". The `CLAIM` layout includes the `u32 epoch`
field after the flags (see the amendment proposed with this change).

# Sharding payloads

| Case | Bytes |
| --- | --- |
| SLOTS "kv", 1024 slots, managed, holder-only, capacity 1 | `6B 76 00 00 00 00 00 00 00 04 00 00 00 00 01 00 00 00` |
| SLOTS "userq", 65536 slots, managed lazy, capacity 0 | `75 73 65 72 71 00 00 00 00 00 01 00 00 01 00 00 00 00` |
| SLOTSPC "room", 256 slots, managed, shared recovery | `72 6F 6F 6D 00 00 00 00 00 01 00 00 00 02` |
| SLOTSPC "discord", 16 slots, static | `64 69 73 63 6F 72 64 00 10 00 00 00 01 00` |
| HOLDING "kv", slots 3 and 258 | `6B 76 00 00 00 00 00 00 02 00 00 00 03 00 00 00 02 01 00 00` |
| HOLDING response, discard slot 258 | `01 00 00 00 02 01 00 00` |
| HOLDING response, nothing to discard | `00 00 00 00` |
| CLAIM "discord" slot 5, no storage, epoch 0 | `64 69 73 63 6F 72 64 00 05 00 00 00 00 00 00 00 00` |
| CLAIM "kv" slot 7, holding, last epoch 9 | `6B 76 00 00 00 00 00 00 07 00 00 00 01 09 00 00 00` |
| CLAIM response, epoch 7 | `07 00 00 00` |
| RELEASE "kv" slot 7, keep storage | `6B 76 00 00 00 00 00 00 07 00 00 00 01` |
| LOCATE "userq" slot 0x1234 | `75 73 65 72 71 00 00 00 34 12 00 00` |
| LOCATE response, owned by 0x1A2B, epoch 7 | `01 2B 1A 00 00 00 00 07 00 00 00` |
| LOCATE response, free, epoch 3 | `00 00 00 00 00 00 00 03 00 00 00` |
| MIGRATE "zone" slot 4 to 0xB | `7A 6F 6E 65 00 00 00 00 04 00 00 00 0B 00 00 00 00 00` |
| MIGRATE "zone" slot 4, allocator chooses | `7A 6F 6E 65 00 00 00 00 04 00 00 00 00 00 00 00 00 00` |
| PHASE draining | `01` |
| PHASE rolled back | `05` |
| ASSIGN "kv" slot 7, epoch 8, holder 2 | `6B 76 00 00 00 00 00 00 07 00 00 00 08 00 00 00 02 00 00 00 00 00 00` |
| ASSIGN "room" slot 1, epoch 1, no holder, shared recovery | `72 6F 6F 6D 00 00 00 00 01 00 00 00 01 00 00 00 00 00 00 00 00 00 01` |
| ASSIGN response, holding | (empty) |
| ASSIGN response, not holding | `01` |
| DRAIN "kv" slot 7, epoch 9, to 3 | `6B 76 00 00 00 00 00 00 07 00 00 00 09 00 00 00 03 00 00 00 00 00` |
| FORWARD "kv" slot 7, epoch 9, to 3 | `6B 76 00 00 00 00 00 00 07 00 00 00 09 00 00 00 03 00 00 00 00 00` |
| RESUME "kv" slot 7, epoch 8 | `6B 76 00 00 00 00 00 00 07 00 00 00 08 00 00 00` |
| SLOT "kv" slot 7, owned by 2, holder 2, epoch 8 | `6B 76 00 00 00 00 00 00 07 00 00 00 01 02 00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 00 00 08 00 00 00` |
| SLOT "kv" slot 7, migrating from 2 to 3, holder 2, epoch 8 | `6B 76 00 00 00 00 00 00 07 00 00 00 02 02 00 00 00 00 00 03 00 00 00 00 00 02 00 00 00 00 00 08 00 00 00` |
| SLOT "kv" slot 7, free, holder 2, epoch 8 | `6B 76 00 00 00 00 00 00 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 00 00 08 00 00 00` |
| SLOT "x" slot 0xFFFFFFFF, owned by 0xFFFFFFFFFFFF, holder 0x123456789ABC, epoch 0xFFFFFFFF | `78 00 00 00 00 00 00 00 FF FF FF FF 01 FF FF FF FF FF FF 00 00 00 00 00 00 BC 9A 78 56 34 12 FF FF FF FF` |

Negative vectors (each MUST be a protocol error):

| Case | Bytes |
| --- | --- |
| SLOTSPC with mode 2 | `6B 76 00 00 00 00 00 00 00 04 00 00 02 00` |
| SLOT with state 3 | `6B 76 00 00 00 00 00 00 07 00 00 00 03 02 00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 00 00 08 00 00 00` |
| HOLDING announcing 2 slots, carrying 1 | `6B 76 00 00 00 00 00 00 02 00 00 00 03 00 00 00` |
| PHASE 0 | `00` |
| PHASE 6 | `06` |
| LOCATE response with state 3 | `03 00 00 00 00 00 00 00 00 00 00` |
| CLAIM without epoch (wiki layout before the amendment) | `6B 76 00 00 00 00 00 00 07 00 00 00 01` |

Unknown flag bits are ignored: `6B 76 00 00 00 00 00 00 00 04 00 00 00 FE`
decodes as SLOTSPC "kv", 1024 slots, managed, shared recovery, not lazy.

`MOVED` reason text: owner `userq/1a2b` at epoch 7 is `userq/1a2b 7`; an
unknown owner is the empty reason.
