import { t } from './i18n';

/** Groups and tags are managed in the same place; this switch sits where the manager's title would be. */
export function ManagerSwitch({ current, onSwitch }: { current: 'groups' | 'tags'; onSwitch: (next: 'groups' | 'tags') => void }) {
  return <div className="dt-tabs dt-manager-switch" role="tablist" aria-label={t('管理')} data-tauri-drag-region>
    {(['groups', 'tags'] as const).map(id => <button key={id} type="button" role="tab" aria-selected={current === id} className={`dt-tab ${current === id ? 'is-on' : ''}`} onClick={() => { if (current !== id) onSwitch(id); }}>{id === 'groups' ? t('分组') : t('标签')}</button>)}
  </div>;
}
