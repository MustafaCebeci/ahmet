// test/integration/controllers/quick-flow.test.js
/**
 * Hizli randevu akisi: autoRegister (sadece quick modda), "beni hatirla" cookie suresi,
 * OTP gonderim siniri, booking_flow_mode dogrulamasi.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createRequire } from 'module';
import path from 'path';
import { fileURLToPath } from 'url';

// controllers.js CommonJS: vi.mock require() cagrilarini yakalamaz, bu yuzden
// bagimliliklari require.cache'e enjekte ediyoruz.
const nodeRequire = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');

const mockPool = {
  execute: vi.fn(),
  query: vi.fn(),
  getConnection: vi.fn(),
};
const mockCustomersCreate = vi.fn();
const mockSendOtp = vi.fn().mockResolvedValue({ ok: true, channel: 'sms' });
const mockVerifyOtp = vi.fn().mockResolvedValue({ ok: true });
let flowMode = 'detailed';

function stub(rel, exports) {
  const id = nodeRequire.resolve(path.join(root, rel));
  nodeRequire.cache[id] = { id, filename: id, loaded: true, exports, children: [], paths: [] };
}

stub('models.js', { pool: mockPool, Models: { customers: { create: mockCustomersCreate } } });
stub('notification.service.js', {
  sendOtp: mockSendOtp,
  verifyOtp: mockVerifyOtp,
  sendCancellationSms: vi.fn(),
});
stub('messageManager.js', { sendNotification: vi.fn() });
stub('sse.js', { emitAppointment: vi.fn(), emitDesktopEvent: vi.fn() });
stub('settingsManager.js', {
  BOOKING_FLOW_MODES: ['detailed', 'quick'],
  getBookingFlowMode: async () => flowMode,
  invalidateBookingFlowModeCache: () => {},
});

const { AuthControllers, ScopedControllers } = nodeRequire(path.join(root, 'controllers.js'));

function makeRes() {
  return {
    status: vi.fn().mockReturnThis(),
    json: vi.fn().mockReturnThis(),
    cookie: vi.fn().mockReturnThis(),
  };
}

let ipCounter = 0;
const freshIp = () => `10.0.0.${++ipCounter}`;

describe('AuthControllers.login() - autoRegister', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    flowMode = 'detailed';
  });

  const unknownPhoneThenOk = () => {
    // 1) customers lookup -> yok, 2) flags, 3) app_settings, 4) aktif randevu sayisi, 5) otp count
    mockPool.execute
      .mockResolvedValueOnce([[]]) // customers SELECT
      .mockResolvedValueOnce([[]]) // customer_flags
      .mockResolvedValueOnce([[{ settings_json: { multiple_appointment_count: 2 } }]]) // app_settings
      .mockResolvedValueOnce([[{ cnt: 0 }]]) // aktif randevu
      .mockResolvedValueOnce([[{ cnt: 0 }]]); // otp_codes count
  };

  it('detailed modda kayitsiz numara 404 + /register yonlendirmesi doner', async () => {
    mockPool.execute.mockResolvedValueOnce([[]]);
    const res = makeRes();
    await AuthControllers.login(
      { ip: freshIp(), body: { userType: 'customer', phone: '5551112233', autoRegister: true } },
      res,
      (e) => { throw e; }
    );
    expect(res.status).toHaveBeenCalledWith(404);
    expect(mockCustomersCreate).not.toHaveBeenCalled();
    expect(mockSendOtp).not.toHaveBeenCalled();
  });

  it('quick modda autoRegister musteriyi olusturur ve OTP gonderir', async () => {
    flowMode = 'quick';
    unknownPhoneThenOk();
    mockCustomersCreate.mockResolvedValueOnce(77);
    const res = makeRes();
    await AuthControllers.login(
      { ip: freshIp(), body: { userType: 'customer', phone: '5551112233', autoRegister: true } },
      res,
      (e) => { throw e; }
    );
    expect(mockCustomersCreate).toHaveBeenCalledWith(expect.objectContaining({ phone: '5551112233', is_active: 1 }));
    expect(mockSendOtp).toHaveBeenCalledWith(expect.objectContaining({ user_type: 'customer', user_id: 77 }));
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ ok: true, userId: 77 }));
  });

  it('quick modda bile autoRegister olmadan kayitsiz numara 404 doner', async () => {
    flowMode = 'quick';
    mockPool.execute.mockResolvedValueOnce([[]]);
    const res = makeRes();
    await AuthControllers.login(
      { ip: freshIp(), body: { userType: 'customer', phone: '5551112233' } },
      res,
      (e) => { throw e; }
    );
    expect(res.status).toHaveBeenCalledWith(404);
    expect(mockCustomersCreate).not.toHaveBeenCalled();
  });

  it('quick modda gecersiz formatli numara kaydedilmez', async () => {
    flowMode = 'quick';
    mockPool.execute.mockResolvedValueOnce([[]]);
    const res = makeRes();
    await AuthControllers.login(
      { ip: freshIp(), body: { userType: 'customer', phone: '4551112233', autoRegister: true } },
      res,
      (e) => { throw e; }
    );
    expect(res.status).toHaveBeenCalledWith(404);
    expect(mockCustomersCreate).not.toHaveBeenCalled();
  });

  it('quick modda randevu limiti dolu numara icin OTP gonderilmez, 400 doner', async () => {
    flowMode = 'quick';
    mockPool.execute
      .mockResolvedValueOnce([[{ id: 5, phone: '5551112233', display_name: 'A', is_active: 1 }]])
      .mockResolvedValueOnce([[]]) // customer_flags
      .mockResolvedValueOnce([[{ settings_json: { multiple_appointment_count: 2 } }]])
      .mockResolvedValueOnce([[{ cnt: 2 }]]);
    const next = vi.fn();
    await AuthControllers.login(
      { ip: freshIp(), body: { userType: 'customer', phone: '5551112233', autoRegister: true } },
      makeRes(),
      next
    );
    expect(next).toHaveBeenCalledWith(
      expect.objectContaining({ status: 400, message: expect.stringContaining('limit') })
    );
    expect(mockSendOtp).not.toHaveBeenCalled();
  });

  it('son 10 dakikada 5 kod istenmisse 429 doner', async () => {
    mockPool.execute
      .mockResolvedValueOnce([[{ id: 5, phone: '5551112233', display_name: 'A', is_active: 1 }]])
      .mockResolvedValueOnce([[]])
      .mockResolvedValueOnce([[{ cnt: 5 }]]);
    const next = vi.fn();
    await AuthControllers.login(
      { ip: freshIp(), body: { userType: 'customer', phone: '5551112233' } },
      makeRes(),
      next
    );
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 429 }));
    expect(mockSendOtp).not.toHaveBeenCalled();
  });
});

describe('AuthControllers.verify() - remember', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockVerifyOtp.mockResolvedValue({ ok: true });
  });

  const customerRows = () =>
    mockPool.execute
      .mockResolvedValueOnce([[{ id: 5, phone: '5551112233', display_name: 'A' }]])
      .mockResolvedValueOnce([[]]);

  it('remember:true -> cookie 90 gun', async () => {
    customerRows();
    const res = makeRes();
    await AuthControllers.verify(
      { body: { userType: 'customer', userId: 5, code: '123456', remember: true } },
      res,
      (e) => { throw e; }
    );
    const opts = res.cookie.mock.calls[0][2];
    expect(opts.maxAge).toBe(90 * 24 * 60 * 60 * 1000);
    expect(opts.httpOnly).toBe(true);
  });

  it('remember yoksa musteri cookie 7 gun', async () => {
    customerRows();
    const res = makeRes();
    await AuthControllers.verify(
      { body: { userType: 'customer', userId: 5, code: '123456' } },
      res,
      (e) => { throw e; }
    );
    expect(res.cookie.mock.calls[0][2].maxAge).toBe(7 * 24 * 60 * 60 * 1000);
  });

  it('remember:true berber icin de 90 gun, yoksa 2 gun', async () => {
    const barberRow = [[{ id: 3, staff_id: 9, is_admin: 1, is_active: 1, staff_name: 'B', staff_phone: '5' }]];

    mockPool.execute.mockResolvedValueOnce(barberRow).mockResolvedValueOnce([{}]);
    const resA = makeRes();
    await AuthControllers.verify(
      { body: { userType: 'barber', userId: 3, code: '123456', remember: true } },
      resA,
      (e) => { throw e; }
    );
    expect(resA.cookie.mock.calls[0][2].maxAge).toBe(90 * 24 * 60 * 60 * 1000);

    mockPool.execute.mockResolvedValueOnce(barberRow).mockResolvedValueOnce([{}]);
    const resB = makeRes();
    await AuthControllers.verify(
      { body: { userType: 'barber', userId: 3, code: '123456' } },
      resB,
      (e) => { throw e; }
    );
    expect(resB.cookie.mock.calls[0][2].maxAge).toBe(2 * 24 * 60 * 60 * 1000);
  });
});

describe('ScopedControllers.businessSettingsUpdate() - booking_flow_mode', () => {
  it('gecersiz booking_flow_mode 400 verir', async () => {
    const jwt = nodeRequire('jsonwebtoken');
    const token = jwt.sign({ sub: 1, typ: 'user' }, process.env.JWT_SECRET);
    mockPool.execute.mockResolvedValueOnce([[{ is_admin: 1, is_active: 1 }]]);
    const next = vi.fn();
    await ScopedControllers.businessSettingsUpdate(
      {
        cookies: { access_token: token },
        params: { id: '1' },
        body: { settings_json: { booking_flow_mode: 'foo' } },
      },
      makeRes(),
      next
    );
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 400 }));
  });
});
