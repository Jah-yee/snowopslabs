interface BadgeProps {
  variant: 'running' | 'stopped' | 'pending' | 'category' | 'runtime'
  children: React.ReactNode
}

export function Badge({ variant, children }: BadgeProps) {
  return <span className={`badge badge-${variant}`}>{children}</span>
}

export function StatusBadge({ active }: { active: boolean }) {
  return <Badge variant={active ? 'running' : 'stopped'}>{active ? 'Active' : 'Inactive'}</Badge>
}

export function DeployedBadge({ deployed }: { deployed: boolean }) {
  return <Badge variant={deployed ? 'running' : 'stopped'}>{deployed ? 'Deployed' : 'Not Deployed'}</Badge>
}

// UnknownBadge stands in for a state that cannot be read, such as while the
// cluster is unreachable - never "Not Installed", which would be a guess.
export function UnknownBadge() {
  return <Badge variant="pending">Unknown</Badge>
}
