/**
 * Shared pushed-page top bar (plan/goal/settings): a back button, a centered
 * single-line title, and an invisible spacer keeping the title optically
 * centered — the same three-column rhythm as the conversation home top bar.
 */
import css from './PageBackBar.module.css'

/** Props: the page title and the back navigation callback. */
export interface PageBackBarProps {
  title: string
  onBack: () => void
}

/** The pushed-page top bar (see module doc). */
export function PageBackBar({ title, onBack }: PageBackBarProps) {
  return (
    <header className={css.bar}>
      <button type="button" className={css.back} onClick={onBack} aria-label="返回">
        ‹
      </button>
      <span className={css.title}>{title}</span>
      <span className={css.spacer} aria-hidden />
    </header>
  )
}
