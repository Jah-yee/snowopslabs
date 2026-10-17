# Hints: liveness-probe-kill

## Hint 1
The restarts are the place to start: `kubectl get pods -n {{.WorkloadNamespace}}`
shows RESTARTS climbing. Before you read any app logs, find out how the last
container ended: `kubectl describe pod -n {{.WorkloadNamespace}} <pod>` and read
**Last State**, its Reason and Exit Code. Did the app exit on its own?

## Hint 2
Exit code 0 and `Reason: Completed` mean the app shut down cleanly because it
was told to: the logs end with it receiving a signal. When the kubelet restarts
a container, it records why in the pod's events. Read the Events at the bottom
of `kubectl describe pod`, or
`kubectl get events -n {{.WorkloadNamespace}} --sort-by=.lastTimestamp`.

## Hint 3
The kubelet restarts a container when its **liveness probe** fails
failureThreshold times in a row. Compare the probe in the Deployment
(`kubectl get deploy {{.WorkloadName}} -n {{.WorkloadNamespace}} -o yaml`, under
`livenessProbe`) with the paths the app really serves. Its own logs show which
path it answers 404 to, every ten seconds.
