import type { SVGProps } from 'react';

type P = SVGProps<SVGSVGElement> & { size?: number };

const base = (size = 22, rest: SVGProps<SVGSVGElement> = {}) => ({
  width: size,
  height: size,
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.8,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  'aria-hidden': true,
  ...rest,
});

const icon = (paths: React.ReactNode, filled = false) =>
  function Icon({ size, ...rest }: P) {
    return <svg {...base(size, rest)} {...(filled ? { fill: 'currentColor', stroke: 'none' } : {})}>{paths}</svg>;
  };

export const IconHome = icon(<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z" />);
export const IconHomeFilled = icon(<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z" />, true);
export const IconSearch = icon(<><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></>);
export const IconExplore = icon(<><circle cx="12" cy="12" r="9" /><path d="m15.5 8.5-2 5-5 2 2-5z" /></>);
export const IconLibrary = icon(<><rect x="4" y="3" width="13" height="16" rx="2" /><path d="M8 21h11a1 1 0 0 0 1-1V7" /><circle cx="10" cy="13" r="2" /><path d="M12 13V7l2.5 1" /></>);
export const IconPlay = icon(<path d="M7 4.5v15a1 1 0 0 0 1.5.86l12.5-7.5a1 1 0 0 0 0-1.72L8.5 3.64A1 1 0 0 0 7 4.5z" />, true);
export const IconPause = icon(<><rect x="6" y="4" width="4" height="16" rx="1" /><rect x="14" y="4" width="4" height="16" rx="1" /></>, true);
export const IconNext = icon(<><path d="M5 5.2v13.6a.8.8 0 0 0 1.2.7l10-6.8a.8.8 0 0 0 0-1.4l-10-6.8a.8.8 0 0 0-1.2.7z" /><rect x="17" y="4" width="2.5" height="16" rx="1" /></>, true);
export const IconPrev = icon(<><path d="M19 5.2v13.6a.8.8 0 0 1-1.2.7l-10-6.8a.8.8 0 0 1 0-1.4l10-6.8a.8.8 0 0 1 1.2.7z" /><rect x="4.5" y="4" width="2.5" height="16" rx="1" /></>, true);
export const IconShuffle = icon(<><path d="M16 3h5v5" /><path d="M4 20 21 3" /><path d="M21 16v5h-5" /><path d="m15 15 6 6" /><path d="M4 4l5 5" /></>);
export const IconRepeat = icon(<><path d="m17 2 4 4-4 4" /><path d="M3 11v-1a4 4 0 0 1 4-4h14" /><path d="m7 22-4-4 4-4" /><path d="M21 13v1a4 4 0 0 1-4 4H3" /></>);
export const IconRepeatOne = icon(<><path d="m17 2 4 4-4 4" /><path d="M3 11v-1a4 4 0 0 1 4-4h14" /><path d="m7 22-4-4 4-4" /><path d="M21 13v1a4 4 0 0 1-4 4H3" /><path d="M11 10h1v4" /></>);
export const IconHeart = icon(<path d="M12 20.5s-7.5-4.6-9.3-9.2C1.5 8 3.7 4.5 7.2 4.5c2 0 3.5 1.1 4.8 2.8 1.3-1.7 2.8-2.8 4.8-2.8 3.5 0 5.7 3.5 4.5 6.8-1.8 4.6-9.3 9.2-9.3 9.2z" />);
export const IconHeartFilled = icon(<path d="M12 20.5s-7.5-4.6-9.3-9.2C1.5 8 3.7 4.5 7.2 4.5c2 0 3.5 1.1 4.8 2.8 1.3-1.7 2.8-2.8 4.8-2.8 3.5 0 5.7 3.5 4.5 6.8-1.8 4.6-9.3 9.2-9.3 9.2z" />, true);
export const IconVolume = icon(<><path d="M4 9v6h4l5 4V5L8 9z" /><path d="M16.5 8.5a5 5 0 0 1 0 7" /><path d="M19 6a8.5 8.5 0 0 1 0 12" /></>);
export const IconVolumeLow = icon(<><path d="M4 9v6h4l5 4V5L8 9z" /><path d="M16.5 8.5a5 5 0 0 1 0 7" /></>);
export const IconMute = icon(<><path d="M4 9v6h4l5 4V5L8 9z" /><path d="m17 9 5 6" /><path d="m22 9-5 6" /></>);
export const IconQueue = icon(<><path d="M3 6h13" /><path d="M3 12h13" /><path d="M3 18h8" /><path d="M17 15v6l4-3z" /></>);
export const IconLyrics = icon(<><path d="M4 5h16v11H9l-5 4z" /><path d="M8 9h8" /><path d="M8 12h5" /></>);
export const IconEq = icon(<><path d="M5 21v-7" /><path d="M5 10V3" /><path d="M12 21v-9" /><path d="M12 8V3" /><path d="M19 21v-5" /><path d="M19 12V3" /><path d="M2.5 14h5" /><path d="M9.5 8h5" /><path d="M16.5 16h5" /></>);
export const IconChevronDown = icon(<path d="m6 9 6 6 6-6" />);
export const IconChevronLeft = icon(<path d="m15 18-6-6 6-6" />);
export const IconChevronRight = icon(<path d="m9 18 6-6-6-6" />);
export const IconMore = icon(<><circle cx="12" cy="5" r="1.6" /><circle cx="12" cy="12" r="1.6" /><circle cx="12" cy="19" r="1.6" /></>, true);
export const IconMoreH = icon(<><circle cx="5" cy="12" r="1.6" /><circle cx="12" cy="12" r="1.6" /><circle cx="19" cy="12" r="1.6" /></>, true);
export const IconPlus = icon(<><path d="M12 5v14" /><path d="M5 12h14" /></>);
export const IconClose = icon(<><path d="M6 6l12 12" /><path d="M18 6 6 18" /></>);
export const IconRadio = icon(<><circle cx="12" cy="12" r="2" /><path d="M16.2 7.8a6 6 0 0 1 0 8.4" /><path d="M7.8 16.2a6 6 0 0 1 0-8.4" /><path d="M19 5a10 10 0 0 1 0 14" /><path d="M5 19A10 10 0 0 1 5 5" /></>);
export const IconBell = icon(<><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" /><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" /></>);
export const IconSettings = icon(<><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" /></>);
export const IconUser = icon(<><circle cx="12" cy="8" r="4" /><path d="M4 21a8 8 0 0 1 16 0" /></>);
export const IconVideo = icon(<><rect x="2.5" y="5" width="14" height="14" rx="2" /><path d="m16.5 10 5-3v10l-5-3" /></>);
export const IconMusic = icon(<><path d="M9 18V5l12-2v13" /><circle cx="6" cy="18" r="3" /><circle cx="18" cy="16" r="3" /></>);
export const IconClock = icon(<><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>);
export const IconTrash = icon(<><path d="M3 6h18" /><path d="M8 6V4h8v2" /><path d="M19 6l-1 14H6L5 6" /></>);
export const IconEdit = icon(<><path d="M12 20h9" /><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z" /></>);
export const IconDrag = icon(<><circle cx="9" cy="6" r="1.3" /><circle cx="15" cy="6" r="1.3" /><circle cx="9" cy="12" r="1.3" /><circle cx="15" cy="12" r="1.3" /><circle cx="9" cy="18" r="1.3" /><circle cx="15" cy="18" r="1.3" /></>, true);
export const IconArrowUp = icon(<><path d="M12 19V5" /><path d="m5 12 7-7 7 7" /></>);
export const IconArrowDown = icon(<><path d="M12 5v14" /><path d="m19 12-7 7-7-7" /></>);
export const IconArrowRight = icon(<><path d="M5 12h14" /><path d="m12 5 7 7-7 7" /></>);
export const IconShare = icon(<><circle cx="18" cy="5" r="3" /><circle cx="6" cy="12" r="3" /><circle cx="18" cy="19" r="3" /><path d="m8.6 13.5 6.8 4" /><path d="m15.4 6.5-6.8 4" /></>);
export const IconExplicit = icon(<><rect x="3" y="3" width="18" height="18" rx="3" /><path d="M10 8h4.5M10 12h4M10 16h4.5M10 8v8" /></>);
export const IconLogout = icon(<><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" /><path d="m16 17 5-5-5-5" /><path d="M21 12H9" /></>);
export const IconCheck = icon(<path d="M20 6 9 17l-5-5" />);
export const IconExpand = icon(<><path d="M15 3h6v6" /><path d="M9 21H3v-6" /><path d="M21 3l-7 7" /><path d="M3 21l7-7" /></>);
export const IconSubtitles = icon(<><rect x="2" y="5" width="20" height="14" rx="2" /><path d="M6 13h4M14 13h4M6 16h8" /></>);
