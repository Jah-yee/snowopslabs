# Hints: missing-secret-key

## Hint 1
Start from the pods: `kubectl get pods -n {{.WorkloadNamespace}}`. Read STATUS:
is any container running at all? A pod whose container never started has no
logs to read, so `kubectl logs` tells you nothing here.

## Hint 2
`CreateContainerConfigError` means the kubelet could not build the container's
configuration, so it never started it. `kubectl describe pod -n
{{.WorkloadNamespace}} <pod>` says why in the Events at the bottom. Restarting
the Deployment builds new pods from the same configuration, and they stop in
the same place.

## Hint 3
The container reads some of its environment from a Secret, one key at a time
(`env[].valueFrom.secretKeyRef` in
`kubectl get deploy {{.WorkloadName}} -n {{.WorkloadNamespace}} -o yaml`).
Compare the key it asks for with the keys the Secret has:
`kubectl describe secret -n {{.WorkloadNamespace}} <secret>` lists them.
