#!/bin/sh

test_description='Test flux inject adds arbitrary custom resources that fluxion can schedule

flux inject appends custom resource vertices -- of any interned type, nested to
any depth, with optional properties -- to an R JGF scheduling graph. This test
injects a nested quantum vendor subtree (qvendor_ibm -> qpu, qvendor_braket ->
qpu), a flat arbitrary custom type (widget), and an extra qpu under an existing
parent selected by type (--at). It then loads the injected graph into
sched-fluxion-resource and confirms the custom resources are matchable: a
generic qpu request matches at depth (any vendor), a vendor-scoped request
selects one vendor subtree, an arbitrary custom type allocates, and a
nonexistent type is unsatisfiable.
'

. `dirname $0`/sharness.sh

base_jgf="${SHARNESS_TEST_SRCDIR}/data/resource/jgfs/hwloc_4core.json"

export FLUX_SCHED_MODULE=none
test_under_flux 1

test_expect_success 'flux inject: nested vendor subtrees via --spec' '
	flux inject --scheduling-only --input ${base_jgf} \
		--spec "{\"type\":\"qvendor_ibm\",\"properties\":{\"ibm\":\"\"},\"with\":[{\"type\":\"qpu\",\"count\":2,\"properties\":{\"ibm\":\"\"}}]}" \
		--spec "{\"type\":\"qvendor_braket\",\"properties\":{\"braket\":\"\"},\"with\":[{\"type\":\"qpu\",\"count\":1,\"properties\":{\"braket\":\"\"}}]}" \
		--output injected.json &&
	test $(jq "[.graph.nodes[].metadata.type]|map(select(.==\"qpu\"))|length" injected.json) -eq 3 &&
	test $(jq "[.graph.nodes[].metadata.type]|map(select(.==\"qvendor_ibm\"))|length" injected.json) -eq 1 &&
	test $(jq "[.graph.nodes[].metadata.type]|map(select(.==\"qvendor_braket\"))|length" injected.json) -eq 1
'

test_expect_success 'flux inject: flat arbitrary custom type via convenience flags' '
	flux inject --scheduling-only --input injected.json \
		--type widget --count 2 --property acme --output injected2.json &&
	mv injected2.json injected.json &&
	test $(jq "[.graph.nodes[].metadata.type]|map(select(.==\"widget\"))|length" injected.json) -eq 2
'

test_expect_success 'flux inject: attach under an existing parent by type (--at)' '
	flux inject --scheduling-only --input injected.json \
		--at qvendor_braket \
		--spec "{\"type\":\"qpu\",\"count\":1,\"properties\":{\"braket\":\"\"}}" \
		--output injected3.json &&
	mv injected3.json injected.json &&
	test $(jq "[.graph.nodes[].metadata.type]|map(select(.==\"qpu\"))|length" injected.json) -eq 4
'

test_expect_success 'injected graph keeps a single root and unique ids' '
	jq -e "([.graph.nodes[].id]|length) == ([.graph.nodes[].id]|unique|length)" injected.json &&
	test $(jq "[.graph.edges[].target] as \$t | .graph.nodes[]|select(.id as \$i | (\$t|index(\$i))|not)|.id" injected.json | wc -l) -eq 1
'

test_expect_success 'flux inject fails with nothing to inject' '
	test_must_fail flux inject --scheduling-only --input ${base_jgf} >/dev/null 2>&1
'

test_expect_success 'flux inject fails on a bad parent type' '
	test_must_fail flux inject --scheduling-only --input ${base_jgf} \
		--at no_such_type --type qpu --count 1 >/dev/null 2>&1
'

test_expect_success 'load fluxion resource against the injected graph' '
	test_might_fail flux module remove sched-fluxion-resource &&
	flux module load sched-fluxion-resource load-file=$(pwd)/injected.json load-format=jgf &&
	flux module list | grep -q sched-fluxion-resource
'

test_expect_success 'write jobspecs' '
	cat >qpu.json <<-EOF &&
	{"version":1,"resources":[{"type":"slot","count":1,"label":"q","with":[{"type":"qpu","count":1}]}],"attributes":{"system":{"duration":60}},"tasks":[{"command":["t"],"slot":"q","count":{"per_slot":1}}]}
	EOF
	cat >ibm.json <<-EOF &&
	{"version":1,"resources":[{"type":"slot","count":1,"label":"q","with":[{"type":"qvendor_ibm","count":1,"with":[{"type":"qpu","count":1}]}]}],"attributes":{"system":{"duration":60}},"tasks":[{"command":["t"],"slot":"q","count":{"per_slot":1}}]}
	EOF
	cat >widget.json <<-EOF &&
	{"version":1,"resources":[{"type":"slot","count":1,"label":"q","with":[{"type":"widget","count":1}]}],"attributes":{"system":{"duration":60}},"tasks":[{"command":["t"],"slot":"q","count":{"per_slot":1}}]}
	EOF
	cat >nope.json <<-EOF
	{"version":1,"resources":[{"type":"slot","count":1,"label":"q","with":[{"type":"nonesuch","count":1}]}],"attributes":{"system":{"duration":60}},"tasks":[{"command":["t"],"slot":"q","count":{"per_slot":1}}]}
	EOF
'

test_expect_success 'generic qpu request matches at depth (any vendor)' '
	flux ion-resource match allocate qpu.json
'

test_expect_success 'vendor-scoped request selects a vendor subtree' '
	flux ion-resource match allocate ibm.json
'

test_expect_success 'arbitrary custom type (widget) allocates' '
	flux ion-resource match allocate widget.json
'

test_expect_success 'nonexistent custom type is unsatisfiable' '
	test_must_fail flux ion-resource match allocate nope.json
'

test_expect_success 'cleanup: remove fluxion resource module' '
	flux module remove -f sched-fluxion-resource
'

test_done
