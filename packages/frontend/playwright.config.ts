import { defineConfig,devices } from "@playwright/test";

export default defineConfig({
  testDir:"./e2e",
  fullyParallel:false,
  workers:1,
  reporter:"line",
  webServer:{command:"npm run dev -- --host 127.0.0.1",url:"http://127.0.0.1:4173",reuseExistingServer:false},
  use:{baseURL:"http://127.0.0.1:4173",trace:"retain-on-failure",launchOptions:{executablePath:"/usr/bin/google-chrome"}},
  projects:[{name:"desktop",use:{...devices["Desktop Chrome"]}},{name:"mobile",use:{...devices["Pixel 7"]}}],
});
