const cron = require("node-cron");
const { runJobs } = require("./scheduler");

function startScheduler() {
    console.log("[CRON] Scheduler başlatıldı (her 5 dakikada)");

    cron.schedule('*/5 * * * *', async () => {
        console.log('[CRON] Zamanlı işlem başlatıldı');
        await runJobs();
    });
}

module.exports = { startScheduler };
