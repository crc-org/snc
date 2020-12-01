package main

import (
	"bytes"
	"context"
	cryptorand "crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"time"

	log "github.com/sirupsen/logrus"
	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	ctrl "sigs.k8s.io/controller-runtime"
)

func main() {
	var caPEM, serverCertPEM, serverPrivKeyPEM *bytes.Buffer
	ca := &x509.Certificate{
		SerialNumber: big.NewInt(2020),
		Subject: pkix.Name{
			Organization: []string{"redhat.com"},
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().AddDate(1, 0, 0),
		IsCA:                  true,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
	}

	// Create private key
	caPrivKey, err := rsa.GenerateKey(cryptorand.Reader, 4096)
	if err != nil {
		fmt.Println(err)
	}

	// Create a self signed CA certificate
	caBytes, err := x509.CreateCertificate(cryptorand.Reader, ca, ca, &caPrivKey.PublicKey, caPrivKey)
	if err != nil {
		fmt.Println(err)
	}

	// PEM encode CA cert
	caPEM = new(bytes.Buffer)
	_ = pem.Encode(caPEM, &pem.Block{
		Type:  "CERTIFICATE",
		Bytes: caBytes,
	})

	dnsNames := []string{"crc-mutating.default.svc"}
	commonName := "crc-mutating.default.svc"

	// server cert config
	cert := &x509.Certificate{
		DNSNames:     dnsNames,
		SerialNumber: big.NewInt(1658),
		Subject: pkix.Name{
			CommonName:   commonName,
			Organization: []string{"redhat.com"},
		},
		NotBefore:    time.Now(),
		NotAfter:     time.Now().AddDate(1, 0, 0),
		SubjectKeyId: []byte{1, 2, 3, 4, 6},
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}

	// server private key
	serverPrivKey, err := rsa.GenerateKey(cryptorand.Reader, 4096)
	if err != nil {
		fmt.Println(err)
	}

	// sign the server cert
	serverCertBytes, err := x509.CreateCertificate(cryptorand.Reader, cert, ca, &serverPrivKey.PublicKey, caPrivKey)
	if err != nil {
		fmt.Println(err)
	}

	// PEM encode the  server cert and key
	serverCertPEM = new(bytes.Buffer)
	_ = pem.Encode(serverCertPEM, &pem.Block{
		Type:  "CERTIFICATE",
		Bytes: serverCertBytes,
	})

	serverPrivKeyPEM = new(bytes.Buffer)
	_ = pem.Encode(serverPrivKeyPEM, &pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(serverPrivKey),
	})

	err = os.MkdirAll("/etc/webhook/certs/", 0666)
	if err != nil {
		log.Panic(err)
	}
	err = WriteFile("/etc/webhook/certs/tls.crt", serverCertPEM)
	if err != nil {
		log.Panic(err)
	}

	err = WriteFile("/etc/webhook/certs/tls.key", serverPrivKeyPEM)
	if err != nil {
		log.Panic(err)
	}

	createMutationConfig(caPEM)
}

// WriteFile writes data in the file at the given path
func WriteFile(filepath string, sCert *bytes.Buffer) error {
	f, err := os.Create(filepath)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = f.Write(sCert.Bytes())
	if err != nil {
		return err
	}
	return nil
}
func createMutationConfig(caCert *bytes.Buffer) {

	var (
		webhookNamespace, _ = os.LookupEnv("CRC_WEBHOOK_NAMESPACE")
		mutationCfgName, _  = os.LookupEnv("CRC_MUTATE_CONFIG")
		webhookService, _   = os.LookupEnv("CRC_WEBHOOK_SERVICE")
	)
	config := ctrl.GetConfigOrDie()
	kubeClient, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic("failed to set go -client")
	}

	path := "/mutate"

	// Ignore if webhook service call is not successful
	fail := admissionregistrationv1.Ignore
	sideEffects := admissionregistrationv1.SideEffectClassNone
	scope := admissionregistrationv1.NamespacedScope

	mutateconfig := &admissionregistrationv1.MutatingWebhookConfiguration{
		ObjectMeta: metav1.ObjectMeta{
			Name: mutationCfgName,
		},
		Webhooks: []admissionregistrationv1.MutatingWebhook{{
			Name: "perftuning.crc.io",
			ClientConfig: admissionregistrationv1.WebhookClientConfig{
				CABundle: caCert.Bytes(),
				Service: &admissionregistrationv1.ServiceReference{
					Name:      webhookService,
					Namespace: webhookNamespace,
					Path:      &path,
				},
			},
			Rules: []admissionregistrationv1.RuleWithOperations{{Operations: []admissionregistrationv1.OperationType{
				admissionregistrationv1.Create},
				Rule: admissionregistrationv1.Rule{
					APIGroups:   []string{"*"},
					APIVersions: []string{"*"},
					Resources:   []string{"pods"},
					Scope:       &scope,
				},
			}},
			FailurePolicy:           &fail,
			AdmissionReviewVersions: []string{"v1beta1", "v1"},
			SideEffects:             &sideEffects,
		}},
	}

	// Retrieve if any other instance of this webhook is present on the cluster
	currentWebhook, err :=
		kubeClient.AdmissionregistrationV1().MutatingWebhookConfigurations().Get(context.TODO(),
			mutationCfgName, metav1.GetOptions{})

	// Remove if any other instnace of this webhook is present on the cluster
	if currentWebhook != nil {
		kubeClient.AdmissionregistrationV1().MutatingWebhookConfigurations().Delete(context.TODO(),
			mutationCfgName, metav1.DeleteOptions{})

	}

	// Create a new instance of this webhook
	if _, err := kubeClient.AdmissionregistrationV1().MutatingWebhookConfigurations().Create(context.TODO(), mutateconfig, metav1.CreateOptions{}); err != nil {
		panic(err)
		fmt.Print(err)
	}
}
