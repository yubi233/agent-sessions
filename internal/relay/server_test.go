package relay

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/store"
)

func TestHealthAndReadiness(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	router := NewServer(db)

	for _, path := range []string{"/healthz", "/readyz"} {
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusOK {
			t.Fatalf("%s returned %d, want %d", path, response.Code, http.StatusOK)
		}
	}
}

func TestReadinessAllowsLocalWebOrigin(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	router := NewServer(db)
	request := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	request.Header.Set("Origin", "http://127.0.0.1:15173")
	response := httptest.NewRecorder()

	router.ServeHTTP(response, request)
	if got := response.Header().Get("Access-Control-Allow-Origin"); got != "http://127.0.0.1:15173" {
		t.Fatalf("CORS origin = %q", got)
	}
}
