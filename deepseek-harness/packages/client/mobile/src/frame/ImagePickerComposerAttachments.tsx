/**
 * Mobile image-picker wrapper around the shared composer attachments surface.
 *
 * The upstream DSH composer adds images through paste/drag only; on a phone
 * WebView there is no desktop drag/drop or clipboard-image path, so the
 * mobile shell registers a small "图片" button plus a hidden file input into
 * the same `conversation.input.attachments` slot. It shadows the default
 * ui-attachment entry (priority -1) and delegates to the original rail/drop/
 * preview component with unchanged props.
 */
import { useRef, type ChangeEvent } from 'react'
import type { ComposerAttachmentsProps } from '@deepseek-ai/dsh-client-ui-conversation/client'
import { ComposerAttachments } from '@deepseek-ai/dsh-client-ui-attachment/src/client/ComposerAttachments.tsx'
import css from './ImagePickerComposerAttachments.module.css'

/** Mobile composer attachments: picker button + hidden file input + original rail. */
export function MobileImagePickerComposerAttachments(props: ComposerAttachmentsProps) {
  const inputRef = useRef<HTMLInputElement | null>(null)
  const { canAcceptDrop, onAddImages, t } = props

  const onFiles = (event: ChangeEvent<HTMLInputElement>): void => {
    const files = Array.from(event.target.files ?? [])
    event.target.value = ''
    if (files.length > 0 && onAddImages !== undefined) {
      onAddImages(files)
    }
  }

  return (
    <div className={css.root} data-mobile-image-picker>
      {canAcceptDrop && onAddImages !== undefined && (
        <button
          type="button"
          className={css.pick}
          onClick={() => { inputRef.current?.click() }}
          title={t('image.label')}
        >
          <span aria-hidden="true">＋</span>
          {t('image.label')}
        </button>
      )}
      <input
        ref={inputRef}
        className={css.input}
        type="file"
        accept="image/*"
        multiple
        onChange={onFiles}
      />
      <ComposerAttachments {...props} />
    </div>
  )
}
