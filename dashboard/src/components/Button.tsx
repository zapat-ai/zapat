import Link from 'next/link'
import { cn } from '@/lib/utils'
import { Button as ShadcnButton, type ButtonProps as ShadcnButtonProps } from '@/components/ui/button'
import { ArrowRight, ArrowLeft } from 'lucide-react'

type ButtonProps = {
  variant?: ShadcnButtonProps['variant']
  arrow?: 'left' | 'right'
} & (
  | (React.ComponentPropsWithoutRef<typeof Link> & { href: string })
  | (React.ComponentPropsWithoutRef<'button'> & { href?: undefined })
)

export function Button({
  variant = 'default',
  className,
  children,
  arrow,
  ...props
}: ButtonProps) {
  const inner = (
    <>
      {arrow === 'left' && <ArrowLeft className="h-4 w-4" />}
      {children}
      {arrow === 'right' && <ArrowRight className="h-4 w-4" />}
    </>
  )

  if (typeof props.href !== 'undefined') {
    const { href, ...linkProps } = props as React.ComponentPropsWithoutRef<typeof Link> & { href: string }
    return (
      <Link href={href} {...linkProps} className={cn(
        'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors',
        'bg-zinc-900 text-zinc-50 shadow hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200',
        'h-9 px-4 py-2',
        className,
      )}>
        {inner}
      </Link>
    )
  }

  return (
    <ShadcnButton variant={variant} className={className} {...(props as React.ComponentPropsWithoutRef<'button'>)}>
      {inner}
    </ShadcnButton>
  )
}
