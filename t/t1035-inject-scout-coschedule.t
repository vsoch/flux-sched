#!/bin/sh

test_description='Scout coschedule: co-allocate node cores AND a vendor qpu via the job path

A small "scout" jobspec requests, together, a classical foothold
(node -> slot -> core; the issue1284 graph has no socket level) AND a vendor
quantum device (qdevice_<vendor> -> qpu, a rack-level device subtree injected
into the graph).

This goes through the JOB path (flux job submit -> qmanager), NOT the direct
"flux ion-resource match allocate" RPC (which does not co-allocate a device in a
sibling subtree). Setup mirrors t1027. The qpu is requested exclusive: a
non-exclusive leaf device is matched but dropped from R (upd_plan only
allocates/emits under excl).
'

. `dirname $0`/sharness.sh

if test_have_prereq ASAN; then
	skip_all='skipping inject scout coschedule test under AddressSanitizer'
	test_done
fi

SIZE=1
test_under_flux ${SIZE}

base_jgf="${SHARNESS_TEST_SRCDIR}/data/resource/jgfs/issue1284.json"

test_expect_success 'inject qdevice_ibm -> qpu (rack-level device) into the graph' '
	flux inject --input ${base_jgf} \
		--at rack \
		--spec "{\"type\":\"qdevice_ibm\",\"properties\":{\"ibm\":\"\"},\"with\":[{\"type\":\"qpu\",\"count\":1,\"properties\":{\"ibm\":\"\"}}]}" \
		--output injected.json &&
	test $(jq "[.. | .metadata? | select(.!=null) | .type] | map(select(.==\"qpu\")) | length" injected.json) -ge 1
'

test_expect_success 'load the full stack against the injected graph' '
	flux module remove sched-simple &&
	flux module remove resource &&
	flux config load <<-EOF2 &&
	[resource]
	noverify = true
	norestrict = true
	path = "$(pwd)/injected.json"
	EOF2
	flux module load resource monitor-force-up &&
	flux module load sched-fluxion-resource match-format=rv1 &&
	flux module load sched-fluxion-qmanager &&
	flux module unload job-list &&
	flux queue start --all --quiet
'

test_expect_success 'write the scout jobspec (node->slot->core AND exclusive qdevice_ibm->qpu)' '
	cat >scout.json <<-EOF2
	{"version":1,"resources":[{"type":"node","count":1,"with":[{"type":"slot","count":1,"label":"scout","with":[{"type":"core","count":1}]}]},{"type":"qdevice_ibm","count":1,"with":[{"type":"qpu","count":1,"exclusive":true}]}],"attributes":{"system":{"duration":60}},"tasks":[{"command":["true"],"slot":"scout","count":{"per_slot":1}}]}
	EOF2
'

test_expect_success 'scout co-allocates a core AND a vendor qpu (reaches alloc)' '
	jobid=$(flux job submit --flags=waitable scout.json) &&
	flux job wait-event -vt10 ${jobid} alloc &&
	flux job wait-event -vt10 ${jobid} clean
'

test_expect_success 'the allocation actually contains a qpu' '
	jobid=$(flux job submit --flags=waitable scout.json) &&
	flux job wait-event -vt10 ${jobid} alloc &&
	flux job info ${jobid} R >R.out &&
	jq -e "[.scheduling.graph.nodes[]?.metadata.type] | any(. == \"qpu\")" R.out &&
	flux job wait-event -vt10 ${jobid} clean
'

test_expect_success 'an unsatisfiable quantum request is rejected (no quota spent)' '
	cat >nope.json <<-EOF2 &&
	{"version":1,"resources":[{"type":"node","count":1,"with":[{"type":"slot","count":1,"label":"scout","with":[{"type":"core","count":1}]}]},{"type":"qdevice_ibm","count":1,"with":[{"type":"qpu","count":99,"exclusive":true}]}],"attributes":{"system":{"duration":60}},"tasks":[{"command":["true"],"slot":"scout","count":{"per_slot":1}}]}
	EOF2
	jobid=$(flux job submit nope.json) &&
	flux job wait-event -vt10 ${jobid} exception >ev.out 2>&1 &&
	grep -qi "unsatisf" ev.out
'

test_expect_success 'cleanup' '
	flux module remove -f sched-fluxion-qmanager &&
	flux module remove -f sched-fluxion-resource
'

test_done
