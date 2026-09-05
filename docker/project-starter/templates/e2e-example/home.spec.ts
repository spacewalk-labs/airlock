import { test, expect } from '@playwright/test'

// async Server Component 는 Vitest 가 렌더할 수 없어 여기서 검증한다.
test('홈페이지가 뜬다', async ({ page }) => {
  const res = await page.goto('/')
  expect(res?.status()).toBeLessThan(400)
  await expect(page.locator('body')).toBeVisible()
})
