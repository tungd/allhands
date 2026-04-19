import { test, expect } from '@playwright/test';

/**
 * E2E tests for All Hands mobile navigation
 * Tests the core navigation flow: login → control room → session view
 */

test.describe('Mobile Navigation', () => {
  test.beforeEach(async ({ page }) => {
    // Login before each test
    await page.goto('/login');
    await page.fill('input[name="username"]', 'td');
    await page.fill('input[name="password"]', '8mGu57TILp27qVRDNi6O');
    await page.click('button[type="submit"]');
    // Wait for redirect
    await page.waitForURL('/control-room', { timeout: 15000 });
    // Wait for page to stabilize
    await page.waitForTimeout(2000);
  });

  test('control room shows session card', async ({ page }) => {
    // Session card should be visible (takes time to load)
    const sessionCard = page.locator('article');
    await expect(sessionCard.first()).toBeVisible({ timeout: 10000 });
    
    // Card should have content (not just empty)
    const cardText = await sessionCard.first().textContent();
    expect(cardText).toBeTruthy();
    expect(cardText!.length).toBeGreaterThan(10);
  });

  test('session card links to session page', async ({ page }) => {
    // Find and click session link
    const sessionLink = page.locator('a[href*="/session/"]');
    await expect(sessionLink.first()).toBeVisible({ timeout: 10000 });
    
    await sessionLink.first().click();
    
    // Should navigate to session URL
    await expect(page).toHaveURL(/\/session\/session_\w+/, { timeout: 10000 });
    
    // Should show session header
    await expect(page.locator('h2')).toBeVisible({ timeout: 5000 });
  });

  test('new session button opens sheet', async ({ page }) => {
    // Click New session link
    await page.click('a[href="/control-room/new"]');
    
    // Should be on /control-room/new URL
    await expect(page).toHaveURL('/control-room/new');
    
    // Should show new session form
    await expect(page.locator('h3').first()).toBeVisible({ timeout: 5000 });
    
    // Should have prompt textarea
    await expect(page.locator('textarea')).toBeVisible({ timeout: 5000 });
  });

  test('topbar navigation links work', async ({ page }) => {
    // Click Inbox link
    await page.click('nav a[href="/inbox"]');
    await expect(page).toHaveURL('/inbox');
    
    // Go back to Control Room
    await page.click('nav a[href="/control-room"]');
    await expect(page).toHaveURL('/control-room');
  });
});

test.describe('Login Flow', () => {
  test('login page renders correctly', async ({ page }) => {
    await page.goto('/login');
    
    // Should have title
    await expect(page).toHaveTitle('All Hands');
    
    // Should have form elements
    await expect(page.locator('input[name="username"]')).toBeVisible();
    await expect(page.locator('input[name="password"]')).toBeVisible();
    await expect(page.locator('button[type="submit"]')).toBeVisible();
  });

  test('login with valid credentials', async ({ page }) => {
    await page.goto('/login');
    await page.fill('input[name="username"]', 'td');
    await page.fill('input[name="password"]', '8mGu57TILp27qVRDNi6O');
    await page.click('button[type="submit"]');
    
    // Should redirect to control-room
    await expect(page).toHaveURL('/control-room', { timeout: 15000 });
    
    // Should show Control Room header
    await expect(page.locator('h2')).toBeVisible({ timeout: 5000 });
  });

  test('login with invalid credentials stays on login', async ({ page }) => {
    await page.goto('/login');
    await page.fill('input[name="username"]', 'wrong');
    await page.fill('input[name="password"]', 'wrong');
    await page.click('button[type="submit"]');
    
    // Should stay on login page (URL may have ?next= param)
    await page.waitForTimeout(2000);
    expect(page.url()).toContain('/login');
  });
});