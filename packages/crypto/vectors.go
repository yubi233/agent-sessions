package crypto

// Vector 是跨语言互解的黄金向量。明文仅存在于测试夹具，不进服务器日志。
type Vector struct {
	Name        string   `json:"name"`
	DEKHex      string   `json:"dek_hex"`
	KeyID       string   `json:"key_id"`
	NonceHex    string   `json:"nonce_hex"`
	Plaintext   string   `json:"plaintext"`
	AAD         AAD      `json:"aad"`
	ExpectOK    bool     `json:"expect_ok"`
	TamperField string   `json:"tamper_field,omitempty"`
	Envelope    Envelope `json:"envelope"`
}
