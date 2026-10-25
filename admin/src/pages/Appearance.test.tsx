import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { adminApi } from '../api';
import { DEFAULT_APPEARANCE } from '../appearance';
import { ToastProvider } from '../hooks';
import { AppearancePage } from './Appearance';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('AppearancePage', () => {
  it('previews unsaved edits and saves the full document without version', async () => {
    vi.spyOn(adminApi.appearance, 'get').mockResolvedValue({ ...structuredClone(DEFAULT_APPEARANCE), version: 'v1', defaults: DEFAULT_APPEARANCE });
    const save = vi.spyOn(adminApi.appearance, 'save').mockImplementation(async (doc: any) => ({ ...doc, version: 'v2' }));
    render(<ToastProvider><AppearancePage /></ToastProvider>);
    const hex = await screen.findByLabelText('Accent hex');
    const phone = screen.getByTestId('phone-preview');
    expect(phone.style.getPropertyValue('--p-accent')).toBe('#E31E2D');
    const saveBtn = screen.getByRole('button', { name: 'Save' }) as HTMLButtonElement;
    expect(saveBtn.disabled).toBe(true);

    fireEvent.change(hex, { target: { value: '1db954' } });
    expect(phone.style.getPropertyValue('--p-accent')).toBe('#1DB954');
    expect(screen.getByText('1 unsaved change', { exact: false })).toBeTruthy();

    fireEvent.click(screen.getByRole('switch', { name: /Show announcement banner/ }));
    expect(saveBtn.disabled).toBe(true); // announcement on but empty → invalid

    fireEvent.click(screen.getByRole('switch', { name: /Show announcement banner/ }));
    fireEvent.click(saveBtn);
    await waitFor(() => expect(save).toHaveBeenCalledTimes(1));
    const body = save.mock.calls[0][0] as any;
    expect(body.version).toBeUndefined();
    expect(body.theme.accent).toBe('#1DB954');
    expect(body.features).toEqual(DEFAULT_APPEARANCE.features);
    await screen.findByText('All changes saved', { exact: false });
  });

  it('discard restores the saved values', async () => {
    vi.spyOn(adminApi.appearance, 'get').mockResolvedValue({ ...structuredClone(DEFAULT_APPEARANCE), version: 'v1' });
    render(<ToastProvider><AppearancePage /></ToastProvider>);
    const radius = await screen.findByLabelText('Corner radius');
    fireEvent.change(radius, { target: { value: '20' } });
    expect(screen.getByTestId('phone-preview').style.getPropertyValue('--p-r')).toBe('20px');
    fireEvent.click(screen.getByRole('button', { name: 'Discard' }));
    expect(screen.getByTestId('phone-preview').style.getPropertyValue('--p-r')).toBe('12px');
  });
});
