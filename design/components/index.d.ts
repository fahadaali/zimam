// زمام — component props (documentation; the bundle assigns window.Zimam).
import type { ReactNode, MouseEventHandler } from 'react';

export interface ButtonProps {
  /** primary: one per screen (brand fill) · secondary: bordered · quiet: text-only brand. Default primary. */
  variant?: 'primary' | 'secondary' | 'quiet';
  disabled?: boolean;
  onClick?: MouseEventHandler<HTMLButtonElement>;
  children: ReactNode;
}

export interface DateChipProps {
  /** Hijri date in Arabic-Indic digits, e.g. "١٢ ربيع الآخر". */
  hijri?: string;
  /** Gregorian date, e.g. "١٤ أكتوبر". Order follows the user's primary calendar. */
  gregorian?: string;
  /** overdue tints the chip priority-high and adds a spoken "متأخرة". */
  tone?: 'default' | 'overdue';
}

export interface PrayerChipProps {
  /** The prayer-relative time, e.g. "بعد العصر بـ٢٠ د". */
  children: ReactNode;
}

export interface TaskRowProps {
  title: ReactNode;
  note?: ReactNode;
  done?: boolean;
  priority?: 'high' | 'medium' | 'low';
  date?: DateChipProps;
  /** Prayer-relative reminder text; renders a PrayerChip. */
  prayer?: ReactNode;
  /** Project name shown as muted meta text. */
  project?: ReactNode;
  /** Selected row in a list (brand-soft ground). */
  selected?: boolean;
  /** Card form used inside KanbanColumn. */
  compact?: boolean;
  /** While dragging: shadow-lift. */
  lifted?: boolean;
  onToggle?: MouseEventHandler<HTMLButtonElement>;
}

export interface ProjectCardProps {
  name: ReactNode;
  done: number;
  total: number;
  due?: DateChipProps;
  /** The project currently open in the sidebar. */
  active?: boolean;
}

export interface KanbanColumnProps {
  title: string;
  /** Defaults to the number of children. */
  count?: number;
  onAdd?: MouseEventHandler<HTMLButtonElement>;
  /** TaskRow elements with compact. */
  children?: ReactNode;
}

export interface AISuggestionProps {
  /** Default "اقتراح المساعد". */
  label?: string;
  children: ReactNode;
  acceptLabel?: string;
  dismissLabel?: string;
  onAccept?: MouseEventHandler<HTMLButtonElement>;
  onDismiss?: MouseEventHandler<HTMLButtonElement>;
}

export declare function Button(props: ButtonProps): JSX.Element;
export declare function TaskRow(props: TaskRowProps): JSX.Element;
export declare function DateChip(props: DateChipProps): JSX.Element;
export declare function PrayerChip(props: PrayerChipProps): JSX.Element;
export declare function ProjectCard(props: ProjectCardProps): JSX.Element;
export declare function KanbanColumn(props: KanbanColumnProps): JSX.Element;
export declare function AISuggestion(props: AISuggestionProps): JSX.Element;
