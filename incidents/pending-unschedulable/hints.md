# Hints: pending-unschedulable

## Hint 1
Count what is serving and what is not:
`kubectl get deploy,rs,pods -n {{.WorkloadNamespace}}`. READY says how many
replicas answer out of how many were asked for. What STATUS are the others in,
and has any of them ever started a container?

## Hint 2
A Pending pod has not been placed on a node yet, so it has no logs and no
restarts. Whatever stopped it, the scheduler wrote the reason into the pod's
events: `kubectl describe pod -n {{.WorkloadNamespace}} <pending-pod>` and read
the Events at the bottom. Deleting the pod only brings back an identical one.

## Hint 3
The scheduler places a pod by its **requests**, compared with what each node
can allocate (`kubectl describe node` → Allocatable and Allocated resources),
never by what the pods actually use (`kubectl top`). Read the CPU request in
the Deployment's pod template
(`kubectl get deploy {{.WorkloadName}} -n {{.WorkloadNamespace}} -o yaml`)
and compare it with a node's allocatable CPU.
