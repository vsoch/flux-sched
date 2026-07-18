#!/bin/sh

test_description='Test the coschedule queuing policy and the group check'

. `dirname $0`/sharness.sh

hwloc_basepath=`readlink -e ${SHARNESS_TEST_SRCDIR}/data/hwloc-data`
# 1 broker, 1 node, 2 sockets, 16 cores
excl_1N1B="${hwloc_basepath}/001N/exclusive/01-brokers"

export FLUX_SCHED_MODULE=none
test_under_flux 1

exec_test()     { ${jq} '.attributes.system.exec.test = {}'; }

# cleanup_active_jobs stops the queue to drain it and leaves it stopped, so
# anything submitted after a cleanup is never handed to the scheduler and just
# waits. Start it again.
drain() {
    cleanup_active_jobs &&
        flux queue start --all --quiet
}

# A held job keeps its footprint and does not start until something releases
# it. That is what coscheduling needs: one half waits while the other arranges
# access to whatever it is waiting for.
held()          { ${jq} '.attributes.system.hold = 1'; }

test_expect_success 'coschedule: generate jobspecs' '
    flux run --dry-run -n1 -t 60m hostname | exec_test > C01.json &&
    flux run --dry-run -n8 -t 60m hostname | exec_test > C08.json &&
    flux run --dry-run -n8 -t 60m hostname | exec_test | held > H08.json
'

test_expect_success 'load test resources' '
    load_test_resources ${excl_1N1B}
'

test_expect_success 'coschedule: the policy loads and names itself' '
    load_resource prune-filters=ALL:core subsystems=containment policy=first &&
    load_qmanager queue-policy=coschedule &&
    test $(flux module stats sched-fluxion-qmanager \
           | ${jq} -r ".queues|to_entries[0].value.policy") = "coschedule"
'

test_expect_success 'coschedule: an ordinary job schedules as backfill would' '
    jobid=$(flux job submit C08.json) &&
    flux job wait-event -t 10 ${jobid} start &&
    drain
'

test_expect_success 'coschedule: a held job keeps its footprint and waits' '
    jobid=$(flux job submit H08.json) &&
    test_must_fail flux job wait-event -t 5 ${jobid} start &&
    test $(flux job list --states=running | wc -l) -eq 0 &&
    drain
'

test_expect_success 'coschedule: work packs around a held job' '
    heldid=$(flux job submit H08.json) &&
    other=$(flux job submit C01.json) &&
    flux job wait-event -t 20 ${other} start &&
    test_must_fail flux job wait-event -t 5 ${heldid} start &&
    drain
'

test_expect_success 'the group check answers, and leaves nothing placed' '
    cat >gcheck.py <<-EOF &&
	import flux
	h = flux.Flux()

	def js(n):
	    return {"version": 1,
	            "resources": [{"type": "slot", "count": n, "label": "s",
	                           "with": [{"type": "core", "count": 1}]}],
	            "tasks": [{"command": ["true"], "slot": "s",
	                       "count": {"per_slot": 1}}],
	            "attributes": {"system": {"duration": 60}}}

	def check(a, b):
	    return h.rpc("sched-fluxion-resource.match_coschedule",
	                 {"check": True,
	                  "jobs": [{"jobspec": js(a), "op": "allocate"},
	                           {"jobspec": js(b), "op": "reserve"}]}).get()

	def placed():
	    r = h.rpc("sched-fluxion-resource.find",
	              {"criteria": "sched-now=allocated",
	               "format": "rv1"}).get()
	    return bool(r.get("R"))

	assert not placed(), "something was placed before the check"
	assert check(8, 1)["fits"], "a pair that fits was refused"
	assert not placed(), "the check left resources placed"
	try:
	    check(8, 9999)
	except OSError:
	    pass
	else:
	    raise SystemExit("a pair that cannot fit was accepted")
	assert not placed(), "a refused check left resources placed"
	print("ok")
	EOF
    flux python gcheck.py
'

test_expect_success 'cleanup active jobs' '
    drain
'

test_expect_success 'removing resource and qmanager modules' '
    remove_qmanager &&
    remove_resource
'

# A held job is only special under coschedule. The other policies do not
# support coscheduling, so a held job there is an ordinary job.
test_expect_success 'easy does not support coscheduling, so hold is ignored' '
    load_resource prune-filters=ALL:core subsystems=containment policy=first &&
    load_qmanager queue-policy=easy &&
    jobid=$(flux job submit H08.json) &&
    flux job wait-event -t 20 ${jobid} start &&
    drain &&
    remove_qmanager &&
    remove_resource
'

test_done
