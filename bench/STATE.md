
## Predskazanie oprovergnuto: slijanie hvosta MoE dajot nol

Three rounds, interleaved, round means 15,16 / 15,18 / 15,25 - drift 0,6%:

    baza          15,20 tok/s   razbros 1,8%   n=3
    so slijaniem  15,19         1,6%           n=3

I predicted 7,4 ms and 16,5-17 tok/s. The measured difference is **0,01 tok/s**, i.e. nothing.

The mechanism is identifiable and the error was mine, in a specific way worth naming. I took a
measured number - the layer graph is 29 nodes, a dispatch costs 7,2 us - and multiplied, without
asking **how many of those 29 nodes run on the device at all**. The MoE tail combines the card's
partial sum with the CPU's, so it executes host-side; cutting its eight nodes cannot touch the
0,470 ms the card spends. The quantity was measured correctly and attributed wrongly.

By the earlier per-layer count on Gemma, the device runs about 11 of 39 nodes. So the ceiling of
"cut nodes" is roughly a third of what I promised, and the barrier and device-occupancy levers -
each measured at about 6,4 ms - are now the larger ones.

**The change stays in regardless.** It is a correctness fix, not an optimisation: bit-identical, and
it is the spelling the reference actually runs (`fused_mmad` defaults true, so the hand-written chain
was the one that did *not* match `llama_decode`). It simply buys no speed.

Method note: this is the third prediction written down before measuring and then refuted - the
scheduler-contention idea, the promotions-blocking idea, and now this one. All three would have been
"plausible optimisations we applied and moved on from" without the prediction step. Writing the
expected number first is what turns a null result into information.
