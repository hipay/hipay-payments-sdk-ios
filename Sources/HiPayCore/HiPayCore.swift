import HiPayFullservice

// Swift facade over the HiPayFullservice KMP framework (architecture D4):
// 100% of the public iOS API lives here; the ObjC export of the KMP framework
// is an internal detail merchants never see.
//
// `HiPay` is the SDK namespace; its members are added by extensions
// (e.g. `HiPay.parseCallback` in HiPayCallback.swift).
public enum HiPay {}
