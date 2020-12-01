package main

import (
	"encoding/json"
	"fmt"
	"html"
	"io/ioutil"
	"log"
	"net/http"
	"strings"
	"time"

	v1beta1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func main() {
	log.Println("Starting server ...")

	mux := http.NewServeMux()

	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/mutate", handleMutate)

	s := &http.Server{
		Addr:           ":8443",
		Handler:        mux,
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
		MaxHeaderBytes: 1 << 20, // 1048576
	}

	log.Fatal(s.ListenAndServeTLS("/etc/webhook/certs/tls.crt", "/etc/webhook/certs/tls.key"))
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "hello %q", html.EscapeString(r.URL.Path))
}

func handleMutate(w http.ResponseWriter, r *http.Request) {
	// read the body / request
	body, err := ioutil.ReadAll(r.Body)
	defer r.Body.Close()

	if err != nil {
		sendError(err, w)
		return
	}

	// mutate the request
	mutated, err := mutate(body, true)
	if err != nil {
		sendError(err, w)
		return
	}

	// and write it back
	w.WriteHeader(http.StatusOK)
	w.Write(mutated)
}

func allowedNameSpace(namespaceName string) bool {
	returnvalue := false
	if len(namespaceName) > 0 &&
		strings.HasPrefix(namespaceName, "openshift-") &&
		!strings.HasPrefix(namespaceName, "openshift-kube-apiserver") &&
		!strings.HasPrefix(namespaceName, "openshift-kube-controller-manager") &&
		!strings.HasPrefix(namespaceName, "openshift-kube-scheduler") &&
		!strings.HasPrefix(namespaceName, "openshift-etcd") {
		returnvalue = true
	}
	return returnvalue
}

func mutate(body []byte, verbose bool) ([]byte, error) {
	// unmarshal request into AdmissionReview struct
	admReview := v1beta1.AdmissionReview{}
	if err := json.Unmarshal(body, &admReview); err != nil {
		return nil, fmt.Errorf("unmarshaling request failed with %s", err)
	}

	var err error
	var pod *corev1.Pod

	responseBody := []byte{}
	ar := admReview.Request
	resp := v1beta1.AdmissionResponse{}

	if ar != nil {

		// get the Pod object and unmarshal it into its struct, if we cannot, we might as well stop here
		if err := json.Unmarshal(ar.Object.Raw, &pod); err != nil {
			return nil, fmt.Errorf("unable unmarshal pod json object %v", err)
		}

		pT := v1beta1.PatchTypeJSONPatch
		resp.PatchType = &pT
		resp.AuditAnnotations = map[string]string{
			"crc-mutate-webhook": "initial resource requests been adjusted by crc-mutate-webhook",
		}

		if allowedNameSpace(ar.Namespace) {

			p := []map[string]string{}
			for i := range pod.Spec.Containers {

				minimalCPUValue := getMinimalCPUValue(ar.Namespace)
				minimalMemoryValue := getMinimalMemoryValue(ar.Namespace)

				// Apply minimal Memory requests
				var memoryPatch map[string]string
				currentMemory := pod.Spec.Containers[i].Resources.Requests.Memory().String()
				if currentMemory != "0" {
					memoryPatch = map[string]string{
						"op":    "replace",
						"path":  fmt.Sprintf("/spec/containers/%d/resources/requests/memory", i),
						"value": minimalMemoryValue,
					}
					p = append(p, memoryPatch)
				}

				// Apply minimal CPU requests
				var cpuPatch map[string]string
				currentCPU := pod.Spec.Containers[i].Resources.Requests.Cpu().String()
				if currentCPU != "0" {
					cpuPatch = map[string]string{
						"op":    "replace",
						"path":  fmt.Sprintf("/spec/containers/%d/resources/requests/cpu", i),
						"value": minimalCPUValue,
					}
					p = append(p, cpuPatch)
				}

				// Remove memory limits
				var memoryLimitsPatch map[string]string
				currentMemoryLimits := pod.Spec.Containers[i].Resources.Limits.Memory().String()
				if currentMemoryLimits != "0" {
					memoryLimitsPatch = map[string]string{
						"op":   "remove",
						"path": fmt.Sprintf("/spec/containers/%d/resources/limits/memory", i),
					}
					p = append(p, memoryLimitsPatch)
				}

				// Remove cpu limits
				var cpuLimitsPatch map[string]string
				currentCPULimits := pod.Spec.Containers[i].Resources.Limits.Cpu().String()
				if currentCPULimits != "0" {
					cpuLimitsPatch = map[string]string{
						"op":   "remove",
						"path": fmt.Sprintf("/spec/containers/%d/resources/limits/cpu", i),
					}
					p = append(p, cpuLimitsPatch)
				}

				if memoryPatch != nil || cpuPatch != nil || memoryLimitsPatch != nil || cpuLimitsPatch != nil {
					resp.Patch, err = json.Marshal(p)
				}
			}
		}
	}

	// set response options
	resp.Allowed = true
	resp.UID = ar.UID

	resp.Result = &metav1.Status{
		Status: "Success",
	}
	admReview.Response = &resp
	responseBody, err = json.Marshal(admReview)
	if err != nil {
		return nil, err
	}
	fmt.Printf(string(responseBody))
	return responseBody, nil
}

func getMinimalCPUValue(namespace string) string {
	minimalCPUValue := "10m"
	return minimalCPUValue
}

func getMinimalMemoryValue(namespace string) string {
	minimalMemoryValue := "10Mi"
	return minimalMemoryValue
}

func sendError(err error, w http.ResponseWriter) {
	log.Println(err)
	w.WriteHeader(http.StatusInternalServerError)
	fmt.Fprintf(w, "%s", err)
}
