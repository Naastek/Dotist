import React from 'react';
import { createRoot } from 'react-dom/client';
import '@fontsource/source-serif-4/600.css';
import '@fontsource/source-sans-3/400.css';
import '@fontsource/source-sans-3/500.css';
import '@fontsource/noto-serif-sc/600.css';
import '@fontsource/noto-sans-sc/400.css';
import '@fontsource/noto-sans-sc/500.css';
import '@fontsource/noto-sans-jp/400.css';
import '@fontsource/noto-sans-jp/500.css';
import '@fontsource/noto-serif-jp/600.css';
import '@fontsource/noto-sans-tc/400.css';
import '@fontsource/noto-sans-tc/500.css';
import '@fontsource/noto-serif-tc/600.css';
import './tokens.css';
import './dotist.css';
import './app.css';
import { App } from './App';
import { QuickAdd } from './QuickAdd';
import { ViewsWindow } from './Views';
import { SettingsWindow } from './Settings';
import { ShadowWindow } from './ShadowWindow';
import { useLang } from './i18n';
import { isDemo } from './taskApi';

const query = new URLSearchParams(window.location.search);
const settingsOnly = query.has('settings');
const viewsOnly = query.has('views');
const quickOnly = query.has('quick');
const shadowOnly = query.has('shadow');
/** Remounts the tree when the language changes, so every translated string is re-read. */
function LangRoot({ children }: { children: React.ReactNode }) {
  const lang = useLang();
  return <React.Fragment key={lang}>{children}</React.Fragment>;
}
if (isDemo) document.documentElement.classList.add('is-demo');
if (settingsOnly) document.documentElement.classList.add('is-settings');
if (viewsOnly) document.documentElement.classList.add('is-views');
if (quickOnly) document.documentElement.classList.add('is-quick');
if (shadowOnly) document.documentElement.classList.add('is-shadow');
createRoot(document.getElementById('root')!).render(<React.StrictMode><LangRoot>{shadowOnly ? <ShadowWindow /> : viewsOnly ? <ViewsWindow /> : settingsOnly ? <SettingsWindow /> : quickOnly ? <QuickAdd /> : <App />}</LangRoot></React.StrictMode>);
