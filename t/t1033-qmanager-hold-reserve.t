#!/bin/sh

test_description='Test that a held job is reserved-first under backfill

Under a backfill policy, a held job stays in the pending set and is
reserved-first every scheduling loop (via the reserve-only match verb),
blocking its footprint without ever allocating, until it is unheld. This is
stronger than merely parking the job: a held job that reserves the whole node
must prevent a lower-priority conflicting job from allocating that node. The
quantum-ready signal is mocked as a direct sched-fluxion-qmanager.hold RPC.
'

. `dirname $0`/sharness.sh

hwloc_basepath=`readlink -e ${SHARNESS_TEST_SRCDIR}/data/hwloc-data`
# 1 broker: 1 node, 2 sockets, 16 cores
excl_1N1B="${hwloc_basepath}/001N/exclusive/01-brokers"

export FLUX_SCHED_MODULE=none
test_under_flux 1

qmanager_hold() {
	flux python -c "
import flux, sys
h = flux.Flux()
h.rpc('sched-fluxion-qmanager.hold',
      {'id': int(sys.argv[1]), 'hold': sys.argv[2] == 'true'}).get()
" "$(flux job id --to=dec $1)" "$2"
}

test_expect_success 'load test resources' '
	load_test_resources ${excl_1N1B}
'

test_expect_success 'load fluxion with the EASY backfill policy' '
	load_resource prune-filters=ALL:core subsystems=containment policy=low &&
	load_qmanager queue-policy=easy
'

# H: held, higher urgency, exclusive whole node.
test_expect_success 'submit a held, high-priority job for the whole node' '
	H=$(flux submit --urgency=25 --setattr=system.hold=1 -N1 -x -t1h sleep 300) &&
	echo $H >H.jobid &&
	test_must_fail flux job wait-event -t 3 $H alloc &&
	test "$(flux jobs -no {state} $H)" = "SCHED"
'

# L: normal, lower urgency, also wants the whole node. Because H is
# reserved-first for the node, L cannot allocate it -- this is the behavior
# that distinguishes reserve-first from parking the held job.
test_expect_success 'a lower-priority conflicting job is blocked by the reservation' '
	L=$(flux submit --urgency=10 -N1 -x -t1h sleep 300) &&
	echo $L >L.jobid &&
	test_must_fail flux job wait-event -t 3 $L alloc &&
	test "$(flux jobs -no {state} $L)" = "SCHED"
'

test_expect_success 'no resources are allocated while only the held job leads' '
	H=$(cat H.jobid) &&
	L=$(cat L.jobid) &&
	test "$(flux jobs -no {state} $H)" != "RUN" &&
	test "$(flux jobs -no {state} $L)" != "RUN"
'

test_expect_success 'unholding the held job allocates it from the front' '
	H=$(cat H.jobid) &&
	qmanager_hold $H false &&
	flux job wait-event -t 30 $H alloc &&
	test "$(flux jobs -no {state} $H)" != "SCHED"
'

test_expect_success 'the lower-priority job remains pending behind it' '
	L=$(cat L.jobid) &&
	test_must_fail flux job wait-event -t 3 $L alloc
'

test_expect_success 'clean up' '
	flux cancel --all &&
	flux queue idle
'

test_expect_success 'remove fluxion modules' '
	remove_qmanager &&
	remove_resource
'

test_done
