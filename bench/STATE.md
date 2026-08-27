
## Pervoe polozhitelnoe chislo puti cherez kartu

Golova (output.weight, 243 MB) na karte, ostalnoe na processore, mx1, prompt_2000, --gen 192:

    processor      12.12 tok/s
    karta          12.61 tok/s     +4.0%,  golova stoit 6.343 ms/tokjen na karte

First time in this project the card has paid on a real model. The head is 243 MB - the smaller part
of the static half, which is 802 MB in total - so this is a fraction of the available lever.

Note the head's measured cost: 6.343 ms against 243 MB / 131 GB/s = 1.9 ms of pure bandwidth. The
difference is the handoff, and it means the transfer and rendezvous around a single once-per-token
tensor cost more than reading it. That is consistent with the measured 177 us per crossing but worth
watching as more of the static half moves: the crossings do not grow with the bytes moved, so
attention (510 MB across 48 layers) will amortise them far better than the head does.

### Pochemu 0.45-0.50% L2 na vyhodah sloev - eto ne oshibka karty

The reference is the fork's own CPU path, and its iqk kernels quantise the activation vector: on one
mul_mat_id against a double-precision reference the CPU measured 5.0e-2 and Vulkan 9.4e-8. So a
half-percent difference between our card path and the CPU reference says "the card computes
differently from the CPU", not "the card computes wrongly" - and by the only measurement we have of
both against ground truth, differently means more accurately.

This matters for how the verification is read. A card path that matched the CPU reference to 1e-7
would be suspicious, not reassuring: it would mean we had reproduced the CPU's activation
quantisation. What must be checked instead is that the difference does not grow with depth - that is
the signature of reassociation compounding, which this project has already been burned by (2.5e-8 at
layer 1 becoming 1.6% by layer 47). Here l_out-23 is 0.4564% and l_out-24 is 0.5024%, so it is
growing slowly; the next thing to look at is the same figure at layer 47.
