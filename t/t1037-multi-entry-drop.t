#!/bin/sh

test_description='A multi-entry jobspec must fail when one top-level entry cannot match

A jobspec may list several top-level resources, e.g. compute (node -> ...)
beside a device (qdevice -> qpu, exclusive) that lives in a sibling subtree
under the cluster. Fluxion matches them in one traversal. When the compute
entry alone is unsatisfiable (a flat node -> slot -> core request on a graph
with sockets, since "with" means direct child), the pair must not match
either. Today it does: the device is allocated, the compute subtree is
silently dropped, and the emitted rv1 R has no execution section. This is
the other face of PR #2 (device dropped beside compute); here the compute is
dropped beside the device. The reverse direction, an unsatisfiable device
beside satisfiable compute, is refused correctly.
'

. `dirname $0`/sharness.sh

query="../../resource/utilities/resource-query"
tiny="${SHARNESS_TEST_SRCDIR}/data/resource/jgfs/tiny.json"

strip_info_lines() {
	grep -v "INFO:"
}

test_under_flux 1

test_expect_success 'inject qdevice_fake-iqm -> qpu[2] at the root of the socket graph' '
	flux inject --scheduling-only --input ${tiny} \
		--spec "{\"type\":\"qdevice_fake-iqm\",\"with\":[{\"type\":\"qpu\",\"count\":2}]}" \
		--output graph.json &&
	test $(jq "[.graph.nodes[].metadata.type] | map(select(. == \"qpu\")) | length" graph.json) -eq 2
'

test_expect_success 'write the jobspecs' '
	cat >flat.json <<-EOF &&
	{"version":1,"resources":[{"type":"node","count":1,"with":[{"type":"slot","count":2,"label":"task","with":[{"type":"core","count":1}]}]}],"tasks":[{"command":["true"],"slot":"task","count":{"per_slot":1}}],"attributes":{"system":{"duration":60}}}
	EOF
	cat >flat-dev.json <<-EOF &&
	{"version":1,"resources":[{"type":"node","count":1,"with":[{"type":"slot","count":2,"label":"task","with":[{"type":"core","count":1}]}]},{"type":"qdevice_fake-iqm","count":1,"with":[{"type":"qpu","count":1,"exclusive":true}]}],"tasks":[{"command":["true"],"slot":"task","count":{"per_slot":1}}],"attributes":{"system":{"duration":60}}}
	EOF
	cat >sock-dev.json <<-EOF &&
	{"version":1,"resources":[{"type":"node","count":1,"with":[{"type":"socket","count":1,"with":[{"type":"slot","count":2,"label":"task","with":[{"type":"core","count":1}]}]}]},{"type":"qdevice_fake-iqm","count":1,"with":[{"type":"qpu","count":1,"exclusive":true}]}],"tasks":[{"command":["true"],"slot":"task","count":{"per_slot":1}}],"attributes":{"system":{"duration":60}}}
	EOF
	cat >sock-bigdev.json <<-EOF
	{"version":1,"resources":[{"type":"node","count":1,"with":[{"type":"socket","count":1,"with":[{"type":"slot","count":2,"label":"task","with":[{"type":"core","count":1}]}]}]},{"type":"qdevice_fake-iqm","count":1,"with":[{"type":"qpu","count":5,"exclusive":true}]}],"tasks":[{"command":["true"],"slot":"task","count":{"per_slot":1}}],"attributes":{"system":{"duration":60}}}
	EOF
'

match() {
	printf "match allocate %s\nquit\n" "$1" | \
		${query} -L graph.json -f jgf -F "$2" -S CA -P first
}

test_expect_success 'the flat compute entry alone does not match a socket graph' '
	match flat.json pretty_simple > flat.out 2>&1 &&
	grep -q "No matching resources found" flat.out
'

test_expect_success 'socket-aware compute beside the device matches both' '
	match sock-dev.json pretty_simple > sock-dev.out 2>&1 &&
	grep -q "RESOURCES=ALLOCATED" sock-dev.out &&
	grep -q "core.*exclusive" sock-dev.out &&
	grep -q "qpu.*exclusive" sock-dev.out
'

test_expect_success 'an unsatisfiable device beside satisfiable compute is refused' '
	match sock-bigdev.json pretty_simple > sock-bigdev.out 2>&1 &&
	grep -q "No matching resources found" sock-bigdev.out
'

test_expect_failure 'an unsatisfiable compute entry beside the device is refused too' '
	match flat-dev.json pretty_simple > flat-dev.out 2>&1 &&
	grep -q "No matching resources found" flat-dev.out
'

test_expect_failure 'the degenerate match does not claim to be an allocation' '
	! grep -q "RESOURCES=ALLOCATED" flat-dev.out
'

test_expect_failure 'and its rv1 R would carry an execution section' '
	match flat-dev.json rv1 > flat-dev.rv1 2>&1 &&
	strip_info_lines < flat-dev.rv1 | jq -e ".execution" >/dev/null
'

test_done
