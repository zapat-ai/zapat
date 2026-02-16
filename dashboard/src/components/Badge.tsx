import { Badge as ShadcnBadge, type BadgeProps } from '@/components/ui/badge'

const colorToVariant: Record<string, BadgeProps['variant']> = {
  success: 'success',
  ok: 'success',
  failure: 'destructive',
  error: 'destructive',
  rework: 'warning',
  fixed: 'warning',
  merged: 'purple',
  closed: 'sky',
  default: 'default',
}

export function Badge({
  children,
  color,
}: {
  children: React.ReactNode
  color?: string
}) {
  const variant = colorToVariant[color || 'default'] || 'default'

  return <ShadcnBadge variant={variant}>{children}</ShadcnBadge>
}
