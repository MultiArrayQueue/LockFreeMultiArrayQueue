/***********************************************************
 * MIT License
 * Copyright (c) 2026 Vít Procházka
 *
 * Promela model of the LockFreeMultiArrayQueue for Spin.
 *
 * An exhaustive verification with more than 2 concurrent writers
 * plus 2 concurrent readers reaches feasibility limits and
 * requires bitstate hashing (-DBITSTATE).
 *
 * Keep in mind that all possible temporal interleaves
 * of all participating threads will be tested
 * (this is where the BlockingMultiArrayQueue is simpler
 * because there the threads cannot interleave "inside").
 *
 * Control the number of concurrent processes by editing
 * WRITERS and READERS below.
 *
 * Recommend to always set a memory limit, e.g.
 *
 *    spin -a LockFreeMultiArrayQueue.pml
 *    cc -O2 -DMEMLIM=512 -o pan pan.c
 *    ./pan
 *
 * A random simulation with Spin, on the contrary,
 * can have a much higher number of concurrent processes:
 *
 *    spin LockFreeMultiArrayQueue.pml
 *
 * The Queue is tested in empty state with FIRST_ARRAY_SIZE == 1
 * which is where the structure is "most dense".
 *
 * However, an optional pre-fill scenario can be specified.
 *
 * TLWACCH = Time Lag When Anything Concurrent Can Happen
 ***********************************************************/

/*********************************************
 verification data
 *********************************************/

// Hint: For construction of the pre-fill scenario it is helpful to use the Interactive Simulator:
// https://MultiArrayQueue.github.io/Simulator_LockFreeMultiArrayQueue.html

// Idea: Run a series of verifications (switch (ideally automatically) PREFILL_STEPS from 0 upwards)
// to test starts from different positions in different fill levels (with FIRST_ARRAY_SIZE 1, CNT_ALLOWED_EXTENSIONS 2).

#define PREFILL_STEPS 0

hidden byte prefill[40] = { 1, 0, 1, 0, 1, 0, 1,
                            1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
                            1, 1, 1, 1,
                            0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 }

#define WRITERS 2
#define READERS 2

hidden short prefillCntEnqueued;
hidden short prefillCntEnqueueFull;

hidden short prefillCntDequeued;
hidden short prefillCntDequeueEmpty;

short cntEnqueued = 0;
short cntEnqueueFull = 0;

short cntDequeued = 0;
short cntDequeueEmpty = 0;

/*********************************************
 private data of the LockFreeMultiArrayQueue
 *********************************************/

#define FIRST_ARRAY_SIZE 1
#define CNT_ALLOWED_EXTENSIONS 2

// MAX_ARRAY_SIZE = FIRST_ARRAY_SIZE * (2 ^ CNT_ALLOWED_EXTENSIONS)
#define MAX_ARRAY_SIZE 4

// MAXIMUM_CAPACITY = SUM( SIZES OF ALL ARRAYS )
#define MAXIMUM_CAPACITY (1+2+4)

// one array element
// 6 bit divertToRix + 1 bit + 57 bit round + 64 bit value = 128 bit (to be CASed with CMPXCHG16B)
typedef element {
    short value = 0;  // the actual payload
    short round = 0;  // to prevent the ABA problem
    bool dirty = false;  // to skip the "round minus one" test in freshly allocated (clean) elements
    byte divertToRix = 0;  // to which ring to divert after this element (0 == do not divert)
}

// the array
typedef array {
    element elements[MAX_ARRAY_SIZE];  // in Promela only uniform lengths, so under-utilized except of the last array
}

// the rings array
array rings[1 + CNT_ALLOWED_EXTENSIONS];

// this models the allocation of the rings array in the real program (in Promela arrays can only be statically allocated)
short ringsAllocMemory[1 + CNT_ALLOWED_EXTENSIONS] = 0;

// one element of the diversions array
// 6 bits rix + 58 bits ix = 64 bit
typedef diversion {
    short ix = 0;
    byte rix = 0;
}

// the diversions array used for the returns (by one shorter because the return from the end of rings[0] to rings[0][0] is implicit)
diversion diversions[CNT_ALLOWED_EXTENSIONS];

// writerPosition points to the next element to be enqueued (stationary state) or the element just enqueued (transient state)
// 6 bit rix + 58 bits ix + 7 bits unused + 57 bit round = 128 bit (to be CASed with CMPXCHG16B)
short writerPositionRound = 0;
byte  writerPositionRix = 0;
short writerPositionIx = 0;

// readerPosition points to the next element to be dequeued (no transient state here)
// 6 bit rix + 58 bits ix + 7 bits unused + 57 bit round = 128 bit (to be CASed with CMPXCHG16B)
short readerPositionRound = 0;
byte  readerPositionRix = 0;
short readerPositionIx = 0;

/*********************************************
 enqueue process
 *********************************************/
proctype enqueue()
{
    short origWriterRound;  // writer position original
    byte  origWriterRix;
    short origWriterIx;
    short writerRound;  // writer position prospective
    byte  writerRix;
    short writerIx;
    short readerRound;  // reader position
    byte  readerRix;
    short readerIx;
    short elementValue;  // element at the writer position
    short elementRound;
    bool  elementDirty;
    byte  elementDivertToRix;
    byte divertToRixNew;  // auxiliary local variables
    bool linearized;
    bool elementCasAssert;  // for assert only
    short cycles = 0;

enqueue_read_writer :

    // read the writer position
    d_step
    {
        origWriterRound = writerPositionRound;
        origWriterRix   = writerPositionRix;
        origWriterIx    = writerPositionIx;
        printf("PID %d (enqueue) has read writerPosition (%d,%d,%d)\n", _pid, origWriterRound, origWriterRix, origWriterIx);
        writerRound = origWriterRound;
        writerRix   = origWriterRix;
        writerIx    = origWriterIx;

        assert(writerIx < (FIRST_ARRAY_SIZE << writerRix));
    }

enqueue_read_reader :

    /*TLWACCH*/

    // read the reader position
    atomic
    {
        readerRound = readerPositionRound;
        readerRix   = readerPositionRix;
        readerIx    = readerPositionIx;
        printf("PID %d (enqueue) has read readerPosition (%d,%d,%d)\n", _pid, readerRound, readerRix, readerIx);

        assert(readerIx < (FIRST_ARRAY_SIZE << readerRix));
        assert(writerRound <= (1 + readerRound));

        if
        :: ((writerRound == (1 + readerRound)) && (writerRix == readerRix) && (writerIx == readerIx)) ->
        {
            // The writer stands on the same place as the reader in the previous round.

            // The writer cannot be in its transient state here, because he (or some competitor) would have to be here
            // in its stationary state before and this wouls have triggered "Queue is full" at that time.
            // And: the reader cannot move back. (no extra TLWACCH: just an assert)
            assert((1 + rings[writerRix].elements[writerIx].round) == writerRound);

            // This can happen only in the fully-extended state (no extra TLWACCH: just an assert)
            assert(0 != ringsAllocMemory[CNT_ALLOWED_EXTENSIONS]);

            // linearization point for Queue full
            cntEnqueueFull ++;
            printf("PID %d found the Queue full on enqueue\n", _pid);
            assert(MAXIMUM_CAPACITY == (cntEnqueued - cntDequeued));

            goto enqueue_done;
        }
        :: else;  // otherwise continue to enqueue_read_element
        fi
    }

enqueue_read_element :

    /*TLWACCH*/

    // read the element at the writer position
    atomic
    {
        cycles ++; assert(cycles <= 8);  // just an assert to detect excessive cycles

        assert(writerIx < ringsAllocMemory[writerRix]);  // check that the array is allocated and we are not out of its bounds

        elementValue       = rings[writerRix].elements[writerIx].value;
        elementRound       = rings[writerRix].elements[writerIx].round;
        elementDirty       = rings[writerRix].elements[writerIx].dirty;
        elementDivertToRix = rings[writerRix].elements[writerIx].divertToRix;
        printf("PID %d (enqueue) has read element rings[%d][%d]\n", _pid, writerRix, writerIx);

        assert((writerRound <= (1 + elementRound)) || (false == elementDirty));

        divertToRixNew = 0;
        linearized = false;
        elementCasAssert = true;

        if
        :: ((writerRound != (1 + elementRound)) && elementDirty) ->  // writer position is in its transient state (or lagging even more)
        {
            printf("PID %d enqueue not tried in rings[%d][%d]\n", _pid, writerRix, writerIx);

            // A writer in transient state cannot hit the reader (in previous round) "from behind",
            // because that reader would be hit by a writer in the stationary state before,
            // which would have reported Queue is full (and the reader cannot move back).
            //
            // With a writer in transient state we must not try the element CAS, which also means
            // that no checking is needed whether a new diversion shouldn't be added.
            //
            // Therefore, go straight to helping to finish an eventual extension and the writer position CAS.
            // For this, it is important that we "know" the correct elementDivertToRix.
            // Let's distinguish two possibilities:
            //
            // A) Our copy of the writer position is "now" still the same as in memory.
            //    But then we have the correct elementDivertToRix, because we must have read the already linearized element
            //    including the eventual new diversion (which is in elementDivertToRix).
            //
            // B) Our copy of the writer position is "now" outdated: Then our writer position CAS will fail.
            //    In the extension helping we will either help if we already "know" a non-zero elementDivertToRix
            //    or not help if we "know" zero (as the only possible old value).

            goto enqueue_extension_help;
        }
        :: else ->  // the writer is in its stationary state
        {
           if
           :: (writerRound == (1 + readerRound)) ->  // reader is in the previous round
           {
                if
                :: ((writerRix == readerRix) && (writerIx == readerIx)) ->  // we stand on the same place as the reader
                {
                    assert(false);  // (1) this would have been handled in enqueue_read_reader
                                    // and (2) on the start-anew-route that skips enqueue_read_reader
                                    // this condition is not possible either
                }
                :: else;
                fi
            }
            :: else ->  // reader is not in the previous round
            {
                assert(writerRound == readerRound);  // now the reader can be only in the same round
            }
            fi
        }
        fi
    }

enqueue_check_if_new_diversion :

    /*TLWACCH*/

    // if no diversion on the element: check if one shouldn't be added
    // the output of this is divertToRixNew (used by the element CAS that follows)
    if
    :: (0 == elementDivertToRix) ->
    {
        atomic
        {
            // The logic of the following loops is: We are now on an element without a diversion. If there is a risk
            // that the Queue might get stuck due to the writer hitting the reader (in the previous round) "from behind"
            // when the Queue is not yet fully extended, then we have to act "now" (in the sense of extending
            // the Queue "now")!

            byte  testNextWriterRix = writerRix;
            short testNextWriterIx  = (1 + writerIx);  // the projected next step

            // So we make a projected next step. First we handle the situation that this goes beyond the end of the ring.
            // If so, we go the diversion returns back (a cascade is possible).
            // No hitting the reader is possible here, because the reader cannot sit at (FIRST_ARRAY_SIZE << rix) == ix.

            do
            :: ((FIRST_ARRAY_SIZE << testNextWriterRix) == testNextWriterIx) ->  // if beyond the end of the ring
            {
                if
                :: (0 == testNextWriterRix) ->  // the return from the end of rings[0] to rings[0][0] is implicit
                {
                    testNextWriterRix = 0;  // move to rings[0][0]
                    testNextWriterIx  = 0;
                    printf("PID %d extend Queue checking implicit return to rings[0][0]\n", _pid);
                    break;
                }
                :: else ->  // follow the diversion back (the diversions entries must exist, no need for extra TLWACCHes)
                {
                    byte tmpRix = testNextWriterRix;
                    testNextWriterRix = diversions[tmpRix - 1].rix;
                    testNextWriterIx  = (1 + diversions[tmpRix - 1].ix);
                    printf("PID %d extend Queue checking real diversion return (%d)\n", _pid, testNextWriterRix);
                }
                fi
            }
            :: else -> break;
            od

            // Once the diversion returns phase is over (or has never begun), we start testing for hitting the reader
            // "from behind" and go eventual diversions forward (a cascade is possible here too).
            // As long as we go, the "risk" we want to eliminate lasts. When can this "risk" be considered "off"?
            // When we find (without hitting the reader! (and the reader cannot go back)) an element without a diversion.
            // Because: Such element allows us to "postpone" the diversion decision until (at least) that element.
            // What if that element is in the last ring where no diversion is possible anymore?
            // Answer: The better: The Queue is then fully extended.
            //
            // note: The conditions (FIRST_ARRAY_SIZE << rix) != ix must now be always fulfilled, because going
            // over diversions forward never goes beyond the end of the ring. However we keep the conditions here
            // for assertion reasons (in the real code they are not needed).

            do
            :: (((FIRST_ARRAY_SIZE << testNextWriterRix) != testNextWriterIx)
             && ((readerRix == testNextWriterRix) && (readerIx == testNextWriterIx))) ->
            {
                // if we hit the reader: we try to extend
                //
                // note 1: Here it is not necessary to test the rounds, because with a writer position in its transient state
                // (or lagging even more) we would not get to here (and to the following element CAS).
                // The element CAS succeeds (and so our result divertToRixNew becomes effective) only if the writer
                // has not yet moved from the stationary state that we have read. But in such case the reader can only be
                // in the previous round strictly ahead of us (because the same place would have triggered "Queue is full"),
                // or in the same round behind us (or on the same place).
                //
                // note 2: In the empty state it could happen that the reader gets ahead of the writer,
                // but only if the writer is transient, which is precluded by note 1.

                printf("PID %d extend Queue checking have hit the reader (%d)\n", _pid, testNextWriterRix);
                goto enqueue_check_if_new_diversion_yes;
            }
            :: (((FIRST_ARRAY_SIZE << testNextWriterRix) != testNextWriterIx)
             && ((readerRix != testNextWriterRix) || (readerIx != testNextWriterIx))
             && (0 == rings[testNextWriterRix].elements[testNextWriterIx].divertToRix)) ->
            {
                // we have reached another place without a diversion (and without the reader):
                // the risk can now be "switched off" (see above), so stop

                printf("PID %d extend Queue checking risk off (%d)\n", _pid, testNextWriterRix);
                goto enqueue_element_cas;
            }
            :: (((FIRST_ARRAY_SIZE << testNextWriterRix) != testNextWriterIx)
             && ((readerRix != testNextWriterRix) || (readerIx != testNextWriterIx))
             && (0 != rings[testNextWriterRix].elements[testNextWriterIx].divertToRix)) ->
            {
                // we have reached a place with a diversion forward (but without the reader):
                // we have to continue to there
                //
                // is it possible that the divertToRix is already there but the new ring is not yet allocated
                // (i.e. the extension helping is not yet finished)? Answer yes: this is possible.
                // But if this happens, then there was a linearization on a different *) element than on our
                // copy of the writer in the stationary state, so our element CAS will fail, so we can stop here.
                // (actually we must stop here to avoid dereferencing a null pointer.)
                //
                // *) (in extreme case of rings[0][0] also possibly the same element)
                //
                // The reading of the element's divertToRix for going over the diversion(s) forward
                // and the testing of ringsAllocMemory is the reason why this is modeled as a separate d_step.
                // Note that this going forward and testing occurs in the same temporal order as the items
                // are laid, so no interleaves can affect the result more than the temporal position
                // of this whole d_step as such: no need for even more TLWACCHes.

                testNextWriterRix = rings[testNextWriterRix].elements[testNextWriterIx].divertToRix;
                testNextWriterIx = 0;

                if
                :: (0 == ringsAllocMemory[testNextWriterRix]) ->
                {
                    printf("PID %d extend Queue checking stopped at not-yet helped divertToRix (%d)\n", _pid, testNextWriterRix);
                    elementCasAssert = false;  // assert the "element CAS will fail" statement above
                    goto enqueue_element_cas;
                }
                :: else ->
                {
                    printf("PID %d extend Queue checking continues with divertToRix (%d)\n", _pid, testNextWriterRix);
                }
                fi
            }
            :: else -> assert(false);  // the conditions above combine to no logical gaps and no logical overlaps
            od
        }
    }
    :: else ->
    {
        goto enqueue_element_cas;
    }
    fi

enqueue_check_if_new_diversion_yes :

    /*TLWACCH*/

    // try to determine divertToRixNew by searching the rings array for the lowest not-yet-allocated ring
    atomic
    {
        // the search is bottom-up and the allocations are also bottom-up, so no interleaves within the search
        // can affect the result more than the temporal position of this whole d_step as such: no need for several TLWACCHes
        //
        // performance: this is a linear search over a very short rings array that is frequently accessed (i.e. is in cache)
        // done only when the Queue considers extending (which might however be frequent in a nearly-full state).
        // Alternative: maintain a separate variable ringsMaxIndex (at the cost of extra CAS).
        //
        // Theoretically this whole d_step could be conditional on "Queue not yet fully extended",
        // which translates to (0 == ringsAllocMemory[CNT_ALLOWED_EXTENSIONS]), but this would add
        // an extra memory read in the mainstream case.

        // search for the lowest not-yet-allocated ring
        assert(0 == divertToRixNew);  // follows from above
        do
        :: (0 == ringsAllocMemory[divertToRixNew]) ->
        {
            break;  // we have found the lowest not-yet allocated ring at divertToRixNew
        }
        :: ((divertToRixNew == CNT_ALLOWED_EXTENSIONS) && (0 != ringsAllocMemory[divertToRixNew])) ->
        {
            divertToRixNew = 0;  // Queue is already fully extended
            break;
        }
        :: ((divertToRixNew < CNT_ALLOWED_EXTENSIONS) && (0 != ringsAllocMemory[divertToRixNew])) ->
        {
            divertToRixNew ++;
        }
        :: else -> assert(false);  // the conditions above combine to no logical gaps and no logical overlaps
        od
        printf("PID %d divertToRixNew %d\n", _pid, divertToRixNew);
    }

enqueue_element_cas :

    /*TLWACCH*/

    // try the element CAS to linearize (this may include implantation of a new diversion)
    atomic
    {
        assert((writerRound == (1 + elementRound)) || (false == elementDirty));  // follows from above
        assert((0 == divertToRixNew) || (0 == elementDivertToRix));  // both never non-zero, follows from above

        if
        :: ((elementValue       == rings[writerRix].elements[writerIx].value)
         && (elementRound       == rings[writerRix].elements[writerIx].round)
         && (elementDirty       == rings[writerRix].elements[writerIx].dirty)
         && (elementDivertToRix == rings[writerRix].elements[writerIx].divertToRix)) ->
        {
            assert(elementCasAssert);

            linearized = true;

            // here is the linearization point, so increment cntEnqueued and write it to the element
            cntEnqueued ++;
            printf("PID %d enqueued %d in rings[%d][%d]\n", _pid, cntEnqueued, writerRix, writerIx);

            rings[writerRix].elements[writerIx].value       = cntEnqueued;
            rings[writerRix].elements[writerIx].round       = writerRound;
            rings[writerRix].elements[writerIx].dirty       = true;
            rings[writerRix].elements[writerIx].divertToRix = (divertToRixNew | elementDivertToRix);  // both never non-zero

            elementValue       = cntEnqueued;     // (not needed later, just for consistency)
            elementRound       = writerRound;     // (not needed later, just for consistency)
            elementDirty       = true;            // (not needed later, just for consistency)
            elementDivertToRix = (divertToRixNew | elementDivertToRix);
        }
        :: else ->  // the element CAS failed, get the current element value (this still goes atomically with CMPXCHG16B)
        {
            printf("PID %d enqueue failed in rings[%d][%d]\n", _pid, writerRix, writerIx);

            // getting the new elementDivertToRix is necessary because the successful linearizer might
            // have done a different decision about the diversion and we now need to know this decision

            elementValue       = rings[writerRix].elements[writerIx].value;  // (not needed later, just for consistency)
            elementRound       = rings[writerRix].elements[writerIx].round;  // (not needed later, just for consistency)
            elementDirty       = rings[writerRix].elements[writerIx].dirty;  // (not needed later, just for consistency)
            elementDivertToRix = rings[writerRix].elements[writerIx].divertToRix;

            assert(writerRound <= elementRound);  // the linearized round can be only equal or higher than "ours"
            assert(true == elementDirty);
        }
        fi
    }

enqueue_extension_help :

    /*TLWACCH*/

    // If we are here with linearized == false, then either the element CAS failed
    // or the element CAS was not even attempted (due to the writer in its the transient state or lagging even more).
    // In both cases this means that "somebody else" has linearized on the writer position instead of us.
    // But we continue anyway to try helping (below).

    // Extension helping
    //
    // Setting ringsAllocMemory[elementDivertToRix] to nonzero is the concluding step 2 of the extension helping,
    // so once nonzero, no extension helping is needed anymore. The respective test shall be quick
    // due to the rings array presumably being in cache.
    atomic
    {
        if
        :: ((0 == elementDivertToRix) || (0 != ringsAllocMemory[elementDivertToRix])) ->
        {
            goto enqueue_writer_position_cas;
        }
        :: else;
        fi
    }

enqueue_extension_help_part_1 :

    /*TLWACCH*/

    // if the extension is not yet finished, finish it - part 1
    // (here we may be helping "somebody else")
    d_step
    {
        // try to CAS the diversion into the diversions array
        // (remark: if the diversion is at (0,0), then this CAS may succeed several times (not an issue))
        if
        :: ((0 == diversions[elementDivertToRix - 1].rix)
         && (0 == diversions[elementDivertToRix - 1].ix)) ->
        {
            // impossible for the position to be written to already exist in the diversions array, but better check ...
            byte tmpRix;
            for (tmpRix : 1 .. CNT_ALLOWED_EXTENSIONS)
            {
                assert((diversions[tmpRix - 1].rix != writerRix)
                    || (diversions[tmpRix - 1].ix  != writerIx)
                    || ((0 == writerRix) && (0 == writerIx)));
            }

            // CAS write part
            printf("PID %d filled diversions[%d]\n", _pid, elementDivertToRix - 1);
            diversions[elementDivertToRix - 1].rix = writerRix;
            diversions[elementDivertToRix - 1].ix  = writerIx;
        }
        :: else ->
        {
            printf("PID %d failed to fill diversions[%d]\n", _pid, elementDivertToRix - 1);

            // the CAS could have failed only due to the desired value already there, but better check ...
            assert((diversions[elementDivertToRix - 1].rix == writerRix)
                && (diversions[elementDivertToRix - 1].ix  == writerIx));
        }
        fi
    }

enqueue_extension_help_part_2 :

    /*TLWACCH*/

    // if the extension is not yet finished, finish it - part 2
    // (here we may be helping "somebody else")
    d_step
    {
        // in the real program: test here once again that the new ring is not yet allocated
        // to reduce unnecessary allocations as much as possible

        printf("PID %d allocated memory for rings[%d]\n", _pid, elementDivertToRix);
        // in the real program: allocate the memory for the new ring ((FIRST_ARRAY_SIZE << elementDivertToRix) elements)

        // try to CAS the new ring into the rings array
        if
        :: (0 == ringsAllocMemory[elementDivertToRix]) ->
        {
            // impossible for that exact memory allocation to already exist, but better check ...
            byte tmpRix;
            for (tmpRix : 0 .. CNT_ALLOWED_EXTENSIONS)
            {
                assert(ringsAllocMemory[tmpRix] != (FIRST_ARRAY_SIZE << elementDivertToRix));
            }

            // CAS write part
            printf("PID %d used allocated memory for rings[%d]\n", _pid, elementDivertToRix);
            ringsAllocMemory[elementDivertToRix] = (FIRST_ARRAY_SIZE << elementDivertToRix);
        }
        :: else ->
        {
            printf("PID %d threw away allocated memory for rings[%d]\n", _pid, elementDivertToRix);
            // in the real program: we have to de-allocate the memory again (pity)

            // the CAS could have failed only due to the desired memory allocation already there, but better check ...
            assert(ringsAllocMemory[elementDivertToRix] == (FIRST_ARRAY_SIZE << elementDivertToRix));
        }
        fi
    }

enqueue_writer_position_cas :

    /*TLWACCH*/

    // now go forward with the writer position and try to CAS it
    // (here we may be helping "somebody else")
    atomic
    {
        if
        :: (0 != elementDivertToRix) ->  // if there is a diversion to be followed forward
        {
            writerRix = elementDivertToRix;
            writerIx  = 0;
        }
        :: else ->  // otherwise
        {
            writerIx ++;  // prospective move up

            do
            :: ((FIRST_ARRAY_SIZE << writerRix) == writerIx) ->  // if beyond the end of the ring
            {
                if
                :: (0 == writerRix) ->  // the return from the end of rings[0] to rings[0][0] is implicit
                {
                    writerRound ++;  // we are passing rings[0][0], so increment round
                    writerRix = 0;  // move to rings[0][0]
                    writerIx  = 0;
                    break;
                }
                :: else ->  // follow the diversion back (the diversions entries must exist, no need for extra TLWACCHes)
                {
                    byte tmpRix = writerRix;
                    writerRix = diversions[tmpRix - 1].rix;
                    writerIx  = (1 + diversions[tmpRix - 1].ix);
                }
                fi
            }
            :: else -> break;
            od
        }
        fi

        // the following is just an assert (so no extra TLWACCH):
        //
        // the step enqueue_check_if_new_diversion is there to eliminate the risk that the Queue gets stuck
        // due to the writer hitting the reader (in the previous round) "from behind" and it has not seen such risk
        // (otherwise it would have eliminated it by creating a new diversion and going to it
        // (except when the Queue was already fully extended, of course))
        //
        // so now: as the reader cannot move back, it is impossible that we hit him, but better check ...
        //
        // note: here we have to test against the readerPosition in memory and not against our copy,
        // because our copy could have indicated an extension, so we would have prepared the extension
        // but then have lost the element CAS to another writer who saw the reader in a later position
        // and has hence not prepared the extension, so we would then (correctly) have gone forward
        // according to the winning writer's decision (i.e. without a diversion), which would make us hit
        // our copy of readerPosition but of course not the "real" readerPosition in memory
        if
        :: (((1 + readerPositionRound) == writerRound)
         && (readerPositionRix == writerRix)
         && (readerPositionIx == writerIx)
         && (0 == ringsAllocMemory[CNT_ALLOWED_EXTENSIONS])  // Queue is not yet fully extended
        ) -> {
            assert(false);
        }
        :: else;
        fi

        assert(writerIx < (FIRST_ARRAY_SIZE << writerRix));

        // CAS the writer position
        if
        :: ((origWriterRound == writerPositionRound)
         && (origWriterRix   == writerPositionRix)
         && (origWriterIx    == writerPositionIx)) ->
        {
            printf("PID %d writerPosition CAS Success (%d,%d,%d)\n", _pid, writerRound, writerRix, writerIx);

            writerPositionRound = writerRound;
            writerPositionRix   = writerRix;
            writerPositionIx    = writerIx;

            // check if our diversion info was right (no extra TLWACCH: just an assert)
            assert(elementDivertToRix == rings[origWriterRix].elements[origWriterIx].divertToRix);
        }
        :: else ->  // the writer position CAS failed: get the current value (this still goes atomically with CMPXCHG16B)
        {
            printf("PID %d writerPosition CAS failed (%d,%d,%d)\n", _pid, writerRound, writerRix, writerIx);

            writerRound = writerPositionRound;
            writerRix   = writerPositionRix;
            writerIx    = writerPositionIx;
        }
        fi

        origWriterRound = writerRound;
        origWriterRix   = writerRix;
        origWriterIx    = writerIx;

        if
        :: (linearized) ->
        {
            goto enqueue_done;  // just finish regardless of the success of the writerPosition CAS
        }
        :: else ->  // Start anew
        {
            // Thanks to the writer position CAS we now have a current copy of the writer position and can omit its re-reading.
            // We now make reasonable efforts to also omit re-reading of the reader position (because it is a memory hot-spot too):
            //
            // The idea is: Normally, after having obtained a new writerPosition, we should also obtain a new readerPosition.
            // But what if our copy of the readerPosition is still "new enough" for us to be sure that it will not interact
            // with the enqueueing in any way (i.e. no Queue full, no Queue extension triggering)?
            //
            // Let's go through the cases:
            //
            // A) If our copy of the readerPosition is in the same round as is now ours, then the readerPosition was somewhere
            //    in the structure "below us" and with the passage of time it could only have come closer to us,
            //    i.e. closer to the "empty state", i.e. closer to "safety". There exists an edge case though, when the reader
            //    sits at readerIx == 0 and when the writer's test in enqueue_check_if_new_diversion would run over the
            //    diversion returns "down to" rings[0][0] and then eventually over diversions forward to some other
            //    rings[rix][0], thus eventually hitting the reader and triggering Queue extension.
            //
            //    Therefore we say that with the exception of that edge case we do not need a newer copy of the readerPosition.
            //
            // B) If our copy of the readerPosition is in the previous round to what is now ours, then the readerPosition
            //    was somewhere in the structure "above us".
            //    Here it gets complex: If we won the writerposition CAS (also went one step forward), we could theoretically
            //    reason about where it wasn't and check the new critical places. If we however lost the writerPosition CAS,
            //    then we might have jumped several steps forward, and then we cannot reason even theoretically.
            //    (This would lead to hardly justifiable complexity anyway (remember we are just optimizing here)).
            //
            //    A "safe" (and simple) case is when our copy of the readerPosition is in the same ring as we are now,
            //    and at least two positions "above us". Then it will not interact with the enqueueing.
            //    If in reality it moved further forward, the better. If there are diversions in between, even much better.
            //
            //    In all other cases we re-read the readerPosition.
            //
            // C) If our copy of the readerPosition is in an older round, then it is outdated and we have to re-read it in any case.

            // (why the "1 +" in this assert: In the empty state the readerPosition can get ahead of the writerPosition
            // in its transient state. Scenario: We have an outdated copy of writerPosition and a recent copy of readerPosition
            // and so our CAS to move the writerPosition forward fails and we get back the a.m. transient state ...
            // This situation can get apparent on the rounds if it occurs at rings[0][0]. This is a rare case
            // and therefore we do not handle it for purposes of optimizing of the re-reading of the readerPosition.)
            assert(readerRound <= (1 + writerRound));

            if
            :: ((writerRound == readerRound) && ((0 != readerIx) || ((FIRST_ARRAY_SIZE << writerRix) != (1 + writerIx)))) ->
            {
                goto enqueue_read_element;
            }
            :: ((writerRound == (1 + readerRound)) && (writerRix == readerRix) && ((1 + writerIx) < readerIx)) ->
            {
                goto enqueue_read_element;
            }
            :: else ->
            {
                goto enqueue_read_reader;
            }
            fi
        }
        fi
    }
enqueue_done :
}

/*********************************************
 dequeue process
 *********************************************/
proctype dequeue()
{
    short origReaderRound;  // reader position original
    byte  origReaderRix;
    short origReaderIx;
    short readerRound;  // reader position prospective
    byte  readerRix;
    short readerIx;
    short elementValue;  // element at the reader position
    short elementRound;
    bool  elementDirty;
    byte  elementDivertToRix;
    short cycles = 0;  // for assert only

dequeue_read_reader :

    d_step  // read the reader position
    {
        origReaderRound = readerPositionRound;
        origReaderRix   = readerPositionRix;
        origReaderIx    = readerPositionIx;
        printf("PID %d (dequeue) has read readerPosition (%d,%d,%d)\n", _pid, origReaderRound, origReaderRix, origReaderIx);
        readerRound = origReaderRound;
        readerRix   = origReaderRix;
        readerIx    = origReaderIx;

        assert(readerIx < (FIRST_ARRAY_SIZE << readerRix));
    }

dequeue_read_element :

    /*TLWACCH*/

    // read the element at the reader position
    atomic
    {
        cycles ++; assert(cycles <= 5);  // just an assert to detect excessive cycles

        assert(readerIx < ringsAllocMemory[readerRix]);  // check that the array is allocated and we are not out of its bounds

        elementValue       = rings[readerRix].elements[readerIx].value;
        elementRound       = rings[readerRix].elements[readerIx].round;
        elementDirty       = rings[readerRix].elements[readerIx].dirty;
        elementDivertToRix = rings[readerRix].elements[readerIx].divertToRix;
        printf("PID %d (dequeue) has read element rings[%d][%d]\n", _pid, readerRix, readerIx);

        assert((readerRound <= (1 + elementRound)) || (false == elementDirty));

        if
        :: ((readerRound == (1 + elementRound)) || (false == elementDirty)) ->
        {
            // linearization point for Queue empty
            cntDequeueEmpty ++;
            printf("PID %d found the Queue empty on dequeue\n", _pid);
            assert(cntEnqueued == cntDequeued);
            goto dequeue_done;
        }
        :: else;
        fi
    }

dequeue_extension_help :

    /*TLWACCH*/

    // Extension helping
    //
    // Setting ringsAllocMemory[elementDivertToRix] to nonzero is the concluding step 2 of the extension helping,
    // so once nonzero, no extension helping is needed anymore. The respective test shall be quick
    // due to the rings array presumably being in cache.
    atomic
    {
        if
        :: ((0 == elementDivertToRix) || (0 != ringsAllocMemory[elementDivertToRix])) ->
        {
            goto dequeue_reader_position_cas;
        }
        :: else;
        fi
    }

dequeue_extension_help_part_1 :

    /*TLWACCH*/

    // if the extension is not yet finished, finish it - part 1
    // (here we may be helping "somebody else")
    d_step
    {
        // try to CAS the diversion into the diversions array
        // (remark: if the diversion is at (0,0), then this CAS may succeed several times (not an issue))
        if
        :: ((0 == diversions[elementDivertToRix - 1].rix)
         && (0 == diversions[elementDivertToRix - 1].ix)) ->
        {
            // impossible for the position to be written to already exist in the diversions array, but better check ...
            byte tmpRix;
            for (tmpRix : 1 .. CNT_ALLOWED_EXTENSIONS)
            {
                assert((diversions[tmpRix - 1].rix != readerRix)
                    || (diversions[tmpRix - 1].ix  != readerIx)
                    || ((0 == readerRix) && (0 == readerIx)));
            }

            // CAS write part
            printf("PID %d filled diversions[%d]\n", _pid, elementDivertToRix - 1);
            diversions[elementDivertToRix - 1].rix = readerRix;
            diversions[elementDivertToRix - 1].ix  = readerIx;
        }
        :: else ->
        {
            printf("PID %d failed to fill diversions[%d]\n", _pid, elementDivertToRix - 1);

            // the CAS could have failed only due to the desired value already there, but better check ...
            assert((diversions[elementDivertToRix - 1].rix == readerRix)
                && (diversions[elementDivertToRix - 1].ix  == readerIx));
        }
        fi
    }

dequeue_extension_help_part_2 :

    /*TLWACCH*/

    // if the extension is not yet finished, finish it - part 2
    // (here we may be helping "somebody else")
    d_step
    {
        // in the real program: test here once again that the new ring is not yet allocated
        // to reduce unnecessary allocations as much as possible

        printf("PID %d allocated memory for rings[%d]\n", _pid, elementDivertToRix);
        // in the real program: allocate the memory for the new ring ((FIRST_ARRAY_SIZE << elementDivertToRix) elements)

        // try to CAS the new ring into the rings array
        if
        :: (0 == ringsAllocMemory[elementDivertToRix]) ->
        {
            // impossible for that exact memory allocation to already exist, but better check ...
            byte tmpRix;
            for (tmpRix : 0 .. CNT_ALLOWED_EXTENSIONS)
            {
                assert(ringsAllocMemory[tmpRix] != (FIRST_ARRAY_SIZE << elementDivertToRix));
            }

            // CAS write part
            printf("PID %d used allocated memory for rings[%d]\n", _pid, elementDivertToRix);
            ringsAllocMemory[elementDivertToRix] = (FIRST_ARRAY_SIZE << elementDivertToRix);
        }
        :: else ->
        {
            printf("PID %d threw away allocated memory for rings[%d]\n", _pid, elementDivertToRix);
            // in the real program: we have to de-allocate the memory again (pity)

            // the CAS could have failed only due to the desired memory allocation already there, but better check ...
            assert(ringsAllocMemory[elementDivertToRix] == (FIRST_ARRAY_SIZE << elementDivertToRix));
        }
        fi
    }

dequeue_reader_position_cas :

    /*TLWACCH*/

    // now go forward with the reader position and try to CAS it
    //
    // Question about if "our" diversion info (elementDivertToRix) is right:
    // Yes, because a potential new diversion is implanted where the writer linearizes and:
    //
    // A) In the "empty case" there is no hazard because we can get to here only after having seen the writer
    //    having linearized on the element, i.e. after also having seen the eventual new diversion
    //    (this is ensured by the "Queue is empty" test).
    //
    // B) In the "full case" the writer cares about creating new diversions if it sees us "ahead", so the hazardous place
    //    is "behind us". Eventual readers with outdated reader position (that may see the hazardous place) will
    //    fail on this reader position CAS.

    atomic
    {
        if
        :: (0 != elementDivertToRix) ->  // if there is a diversion to be followed forward
        {
            readerRix = elementDivertToRix;
            readerIx  = 0;
        }
        :: else ->  // otherwise
        {
            readerIx ++;  // prospective move up

            do
            :: ((FIRST_ARRAY_SIZE << readerRix) == readerIx) ->  // if beyond the end of the ring
            {
                if
                :: (0 == readerRix) ->  // the return from the end of rings[0] to rings[0][0] is implicit
                {
                    readerRound ++;  // we are passing rings[0][0], so increment round
                    readerRix = 0;  // move to rings[0][0]
                    readerIx  = 0;
                    break;
                }
                :: else ->  // follow the diversion back (the diversions entries must exist, no need for extra TLWACCHes)
                {
                    byte tmpRix = readerRix;
                    readerRix = diversions[tmpRix - 1].rix;
                    readerIx  = (1 + diversions[tmpRix - 1].ix);
                }
                fi
            }
            :: else -> break;
            od
        }
        fi

        assert(readerIx < (FIRST_ARRAY_SIZE << readerRix));

        // CAS the reader position
        if
        :: ((origReaderRound == readerPositionRound)
         && (origReaderRix   == readerPositionRix)
         && (origReaderIx    == readerPositionIx)) ->
        {
            printf("PID %d readerPosition CAS Success (%d,%d,%d)\n", _pid, readerRound, readerRix, readerIx);

            readerPositionRound = readerRound;
            readerPositionRix   = readerRix;
            readerPositionIx    = readerIx;

            // check if our diversion info was right (no extra TLWACCH: just an assert)
            assert(elementDivertToRix == rings[origReaderRix].elements[origReaderIx].divertToRix);

            // Having successfully moved away from an element was the linearization point of the dequeue,
            // so increment cntDequeued and compare it with elementValue.
            cntDequeued ++;
            printf("PID %d dequeued %d in rings[%d][%d]\n", _pid, elementValue, origReaderRix, origReaderIx);
            assert(cntDequeued == elementValue);  // this verifies the correct FIFO order

            goto dequeue_done;
        }
        :: else ->  // the reader position CAS failed: get the current value (this still goes atomically with CMPXCHG16B)
        {
            printf("PID %d readerPosition CAS failed (%d,%d,%d)\n", _pid, readerRound, readerRix, readerIx);

            readerRound = readerPositionRound;
            readerRix   = readerPositionRix;
            readerIx    = readerPositionIx;

            origReaderRound = readerRound;
            origReaderRix   = readerRix;
            origReaderIx    = readerIx;

            // Thanks to the reader position CAS we now have a current copy of the reader position and can omit its re-reading.
            goto dequeue_read_element;
        }
        fi
    }
dequeue_done :
}

/*********************************************
 init process
 *********************************************/
init
{
    pid pids[WRITERS + READERS];
    short idx;

    // initialization of the Queue
    ringsAllocMemory[0] = FIRST_ARRAY_SIZE;

    // prefill scenario (enqueues/dequeues one after the other)
    for (idx: 0 .. PREFILL_STEPS - 1)
    {
        // start process
        if
        :: (1 == prefill[idx]) ->
        {
            pids[0] = run enqueue();
            printf("init: pre-fill enqueue process %d\n", pids[0]);
        }
        :: else ->
        {
            pids[0] = run dequeue();
            printf("init: pre-fill dequeue process %d\n", pids[0]);
        }
        fi

        // join process
        (_nr_pr <= pids[0]);
        printf("init: joined pre-fill process %d\n", pids[0]);
    }

    prefillCntEnqueued     = cntEnqueued;
    prefillCntEnqueueFull  = cntEnqueueFull;
    prefillCntDequeued     = cntDequeued;
    prefillCntDequeueEmpty = cntDequeueEmpty;

    // start all writer + reader processes concurrently
    atomic
    {
        for (idx: 0 .. (WRITERS - 1))
        {
            pids[idx] = run enqueue();
            printf("init: enqueue process %d\n", pids[idx]);
        }
        for (idx: WRITERS .. (WRITERS + READERS - 1))
        {
            pids[idx] = run dequeue();
            printf("init: dequeue process %d\n", pids[idx]);
        }

        printf("init: initialized all processes\n");
    }

    // join the concurrent processes
    for (idx: 0 .. (WRITERS + READERS - 1))
    {
        (_nr_pr <= pids[WRITERS + READERS - 1 - idx]);
        printf("init: joined process %d\n", pids[WRITERS + READERS - 1 - idx]);
    }

    // balance of enqueues
    assert(WRITERS == (cntEnqueued + cntEnqueueFull - (prefillCntEnqueued + prefillCntEnqueueFull)));

    // balance of dequeues
    assert(READERS == (cntDequeued + cntDequeueEmpty - (prefillCntDequeued + prefillCntDequeueEmpty)));

    // now: except when the concurrent phase resulted in an empty Queue (unlikely but possible),
    // start reader processes one-after-the-other to empty the Queue
    // and then check that the Queue is indeed empty

    short tmpCnt = cntEnqueued - cntDequeued;
    printf("init: left in the Queue %d\n", tmpCnt);

    for (idx: 0 .. (tmpCnt - 1))
    {
        // start process
        pids[0] = run dequeue();
        printf("init: clean-up dequeue process %d\n", pids[0]);

        // join process
        (_nr_pr <= pids[0]);
        printf("init: joined clean-up process %d\n", pids[0]);
    }

    // the Queue must be empty now
    assert(cntEnqueued == cntDequeued);

    // one extra dequeue to make sure that the Queue indeed reports empty
    tmpCnt = cntDequeueEmpty;

    // start process
    pids[0] = run dequeue();
    printf("init: extra dequeue process %d\n", pids[0]);

    // join process
    (_nr_pr <= pids[0]);
    printf("init: joined extra process %d\n", pids[0]);

    assert((1 + tmpCnt) == cntDequeueEmpty)
}

/*
   _    _ _  _ ____ ____ ____ _ ___  ____ ___  _ _    _ ___ _   _
   |    | |\ | |___ |__| |__/ |   /  |__| |__] | |    |  |   \_/
   |___ | | \| |___ |  | |  \ |  /__ |  | |__] | |___ |  |    |

Linearizability (mainly by Herlihy and Wing) is an important concept in proving correctness of concurrent algorithms.

In practical terms, linearizability condenses to establishing linearization points, which are indivisible points in time
at which the operations instantaneously take effect.

The idea is that by ordering the concurrently running operations by their linearization points, one obtains
a linear (i.e. sequential / single-threaded) execution history of that operations that give the same results.

It is advantageous to prove linearizability theoretically via the linearization points,
not only because it provides insights, but also because testing it experimentally may be intractable:
Imagine a situation with 10 threads running operations on the Queue concurrently.
How big would be the set of linear / single-threaded execution histories (permutations) of these 10 operations
on the same Queue to compare any concurrent result with: 10! = 3,6 million.

The following explanations/proofs are given in Plain English without mathematical formalisms.

Operation 1: Enqueue
--------------------

The linearization point is the successful element CAS that exchanges the original contents
of the element (with old (i.e. "minus one") round number) against the new contents (a new value/payload
with a new round number and eventually also with a new divertToRix (a starting point of a Queue extension)).

Unsuccessful element CASes are followed by repetitions until a successful element CAS (or until Queue is full).

Other actions in the enqueue function do not constitute linearization points and can be helped by other threads:
 * Helping to finish a Queue extension by writing the needed record into the diversions[] array - via a CAS on that array.
 * Helping to finish a Queue extension by allocating the memory needed for the new ring and writing a pointer to it
   into the rings[] array - via a CAS on that array.
 * Helping the writerPosition move from its transient state (where it points to the element that was just successfully linearized)
   to its stationary state (pointing to the "next to be written" element) - via a CAS on writerPosition.

Operation 2: A failed Enqueue (due to full Queue)
-------------------------------------------------

This outcome is reached if the writer position (in its stationary state) stands on the same place
as the readerPosition in the previous round.

Because writerPosition is read first, and both positions can only move forward,
and writerPosition can never get ahead of the readerPosition in the previous round,
the first sentence means that the writerPosition must not have moved forward between the two reads.

So the second read is the linearization point and at that instant the Queue must have indeed been full
(i.e. the difference between the counts of Enqueue linearization points and Dequeue linearization points
must have been equal to the maximum capacity of the Queue at that instant).

For "Queue is full", this all must have happened in a situation when the Queue was already fully extended.
But this condition is guaranteed by the extension logic: If the reader in the previous round is seen "ahead"
(possibly also in a cascade of diversion returns and/or diversions forward), the Queue would extend,
which means that the writer would divert (and hence not catch the reader) at the next Enqueue.
Only when no extensions are possible anymore, then the writer can catch the reader in the previous round.

Operation 3: Dequeue
--------------------

The linearization point is the successful readerPosition CAS that moves the readerPosition away from an element.
The value/payload on that element (that of course must have been read before the CAS) is then the just-dequeued value.

Unsuccessful readerPosition CASes are followed by repetitions until a successful readerPosition CAS (or until Queue is empty).

Other actions in the dequeue function do not constitute linearization points and can be helped by other threads:
 * Helping to finish a Queue extension by writing the needed record into the diversions[] array - via a CAS on that array.
 * Helping to finish a Queue extension by allocating the memory needed for the new ring and writing a pointer to it
   into the rings[] array - via a CAS on that array.

The dequeue function does not help the writerPosition move out from its transient state, because for dequeueing,
this is not a blocker (the dequeue function does not even read writerPosition).

Operation 4: A failed Dequeue (due to empty Queue)
--------------------------------------------------

This outcome is reached if the readerPosition points to an element which either was never written (dirty flag false)
or the reader's round is (by one) higher than that element's round (meaning that that element was not yet
linearized in the "right" round).

Because readerPosition is read first, and both the readerPosition as well as the linearizations on the elements
can only move forward, and readerPosition can never get ahead of the linearizations,
this means that the readerPosition must not have moved forward between the two reads.

So the second read is the linearization point and at that instant the Queue must have indeed been empty
(i.e. the count of Dequeue linearization points must have been equal to the count of Enqueue linearization points
at that instant).

*/

