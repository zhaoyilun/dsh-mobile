/**
 * Mobile image-picker wrapper around the shared composer attachments surface.
 *
 * The upstream DSH composer adds images through paste/drag only; on a phone
 * WebView there is no desktop drag/drop or clipboard-image path, so the
 * mobile shell registers a small "图片" label plus a native file input into
 * the same `conversation.input.attachments` slot. The label is the
 * interaction target: a native `<label>` wrapping the input is the most
 * reliable way to open the Android file chooser from a WebView.
 */
import { useRef, type ChangeEvent } from 'react'
import type { ComposerAttachmentsProps } from '@deepseek-ai/dsh-client-ui-conversation/client'
import { ComposerAttachments } from '@deepseek-ai/dsh-client-ui-attachment/src/client/ComposerAttachments.tsx'
import css from './ImagePickerComposerAttachments.module.css'

/** Mobile composer attachments: native label/file input + original rail. */
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
        <label className={css.pick} title={t('image.label')}>
          <span aria-hidden="true">＋</span>
          {t('image.label')}
          <input
            ref={inputRef}
            className={css.input}
            type="file"
            accept="image/*"
            multiple
            onChange={onFiles}
          />
        </label>
      )}
      <ComposerAttachments {...props} />
    </div>
  )
}
