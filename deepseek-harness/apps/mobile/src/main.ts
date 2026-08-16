/**
 * Mobile application entry: thin bootstrap over the mobile shell library.
 * Everything — loader holding, module-table seeding, AppRoot gate, mobile
 * frame assembly — lives in @deepseek-ai/dsh-client-mobile; this file only
 * finds the mount point.
 */
import { AppMobileEntry } from '@deepseek-ai/dsh-client-mobile'

const el = document.getElementById('root')
if (el === null) throw new Error('mobile app: missing #root')
void new AppMobileEntry(el).run()
