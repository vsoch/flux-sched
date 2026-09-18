#!/bin/sh

test_description='Test qmanager hold/unhold of pending jobs

A job submitted with attributes.system.hold is parked out of the scheduling
loop and never allocated until it is unheld via the
sched-fluxion-qmanager.release RPC. This models the "scout" pattern: a small
foothold job holds an external resource (e.g. a quantum session) and, when
that resource is ready, fires the unhold RPC on its paired classical job.
Here the external signal is mocked as a direct RPC call.
'

. `dirname $0`/sharness.sh

hwloc_basepath=`readlink -e ${SHARNESS_TEST_SRCDIR}/data/hwloc-data`
# 1 broker: 1 node, 2 sockets, 16 cores (8 per socket)
excl_1N1B="${hwloc_basepath}/001N/exclusive/01-brokers"

export FLUX_SCHED_MODULE=none
test_under_flux 1

# Fire the sched-fluxion-qmanager.release RPC. Args: <jobid(F58)>
qmanager_release() {
	flux python -c "
import flux, sys
h = flux.Flux()
h.rpc('sched-fluxion-qmanager.release',
      {'id': int(sys.argv[1])}).get()
" "$(flux job id --to=dec $1)"
}

test_expect_success 'load test resources' '
	load_test_resources ${excl_1N1B}
'

test_expect_success 'load fluxion modules' '
	load_resource &&
	load_qmanager_sync
'

test_expect_success 'a held job is accepted and stays pending (SCHED)' '
	jobid=$(flux submit --setattr=system.hold=1 -n1 sleep 300) &&
	echo $jobid >held.jobid &&
	test_must_fail flux job wait-event -t 3 $jobid alloc &&
	test "$(flux jobs -no {state} $jobid)" = "SCHED"
'

test_expect_success "the held job's resources are not consumed" '
	test $(flux job list --states=running | wc -l) -eq 0
'

test_expect_success "held job does not block the queue: a normal job runs" '
	flux run -n1 sleep 0
'

test_expect_success "unholding a job with a bad id fails (ENOENT)" '
	test_must_fail flux python -c "
import flux
flux.Flux().rpc(\"sched-fluxion-qmanager.release\",
                {\"id\": 123456789012345}).get()
"
'

test_expect_success 'unhold allocates the job on the next loop' '
	jobid=$(cat held.jobid) &&
	qmanager_release $jobid &&
	flux job wait-event -t 30 $jobid alloc &&
	test "$(flux jobs -no {state} $jobid)" != "SCHED"
'

test_expect_success 'a job held then unheld before matching also runs' '
	jobid=$(flux submit --setattr=system.hold=1 -n1 sleep 0) &&
	test_must_fail flux job wait-event -t 3 $jobid alloc &&
	qmanager_release $jobid &&
	flux job wait-event -t 30 $jobid clean
'

test_expect_success 'a held job can be canceled while held' '
	jobid=$(flux submit --setattr=system.hold=1 -n1 sleep 300) &&
	test_must_fail flux job wait-event -t 3 $jobid alloc &&
	flux cancel $jobid &&
	flux job wait-event -t 30 $jobid clean
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
