// =============================================================================
// ModelDeployment Operator — platform/controller/main.go
// =============================================================================
//
// Single-file scaffold demonstrating the kubebuilder/controller-runtime
// operator pattern at Staff-level architectural depth.
//
// Directory layout (full operator project):
//
//   platform/controller/
//   ├── main.go                     ← this file (bootstrap + types + reconciler)
//   ├── go.mod
//   ├── go.sum
//   ├── Makefile                    ← make manifests / generate / build / test
//   ├── config/
//   │   ├── crd/bases/              ← generated CRD YAML (make manifests)
//   │   ├── rbac/                   ← generated ClusterRole/Binding YAML
//   │   ├── manager/                ← Deployment manifest for the operator pod
//   │   └── default/                ← kustomize overlay wiring it all together
//   ├── api/v1alpha1/               ← in a real project, types live here
//   └── controllers/                ← in a real project, reconciler lives here
//
// For this scaffold everything is colocated in main.go so the learning path
// is linear: read top-to-bottom to understand the full operator lifecycle.
//
// Run locally (against a Kind cluster):
//   go run ./main.go --kubeconfig ~/.kube/config --leader-elect=false
//
// Install CRD before running:
//   make manifests && kubectl apply -f config/crd/bases/
//
// Dependencies (go.mod):
//   sigs.k8s.io/controller-runtime  v0.19.x
//   k8s.io/api                      v0.31.x
//   k8s.io/apimachinery             v0.31.x
//   k8s.io/client-go                v0.31.x
//
// =============================================================================

package main

import (
	"context"
	"fmt"
	"os"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/intstr"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

// =============================================================================
// API Types — ModelDeployment CRD
// =============================================================================
//
// In a kubebuilder project these would live in api/v1alpha1/types.go.
// The +kubebuilder markers are parsed by controller-gen to produce:
//   - CRD YAML (config/crd/bases/)
//   - RBAC ClusterRole (config/rbac/)
//   - DeepCopy implementations (_types_deepcopy.go)

// ServingRuntimeType enumerates the supported inference server backends.
// +kubebuilder:validation:Enum=vllm;ollama;triton
type ServingRuntimeType string

const (
	ServingRuntimeVLLM   ServingRuntimeType = "vllm"
	ServingRuntimeOllama ServingRuntimeType = "ollama"
	ServingRuntimeTriton ServingRuntimeType = "triton"
)

// ModelDeploymentPhase represents the high-level lifecycle state.
// +kubebuilder:validation:Enum=Pending;Running;Failed;Scaling;Terminating
type ModelDeploymentPhase string

const (
	PhasePending     ModelDeploymentPhase = "Pending"
	PhaseRunning     ModelDeploymentPhase = "Running"
	PhaseFailed      ModelDeploymentPhase = "Failed"
	PhaseScaling     ModelDeploymentPhase = "Scaling"
	PhaseTerminating ModelDeploymentPhase = "Terminating"
)

// ModelDeploymentFinalizer is added to every ModelDeployment on creation.
// The reconciler blocks deletion until cleanup logic completes.
const ModelDeploymentFinalizer = "platform.ai/modeldeployment-finalizer"

// AutoscalingConfig defines KEDA-based horizontal scaling parameters.
type AutoscalingConfig struct {
	// MinReplicas is the floor for scale-down. Defaults to 1 (no scale-to-zero
	// to avoid cold-start TTFT spikes in interactive workloads).
	// +kubebuilder:default=1
	// +kubebuilder:validation:Minimum=0
	MinReplicas int32 `json:"minReplicas,omitempty"`

	// MaxReplicas is the ceiling for scale-up.
	// +kubebuilder:validation:Minimum=1
	MaxReplicas int32 `json:"maxReplicas"`

	// TargetKVCacheUtilization is the DCGM KV-cache fill ratio (0.0–1.0) at
	// which KEDA should scale up. 0.80 means "add a replica at 80% cache full".
	// +kubebuilder:default="0.80"
	TargetKVCacheUtilization string `json:"targetKVCacheUtilization,omitempty"`

	// TargetQueueDepth triggers scale-up when pending request queue exceeds
	// this count. Pairs with vllm_num_requests_waiting Prometheus metric.
	// +kubebuilder:default=10
	TargetQueueDepth int32 `json:"targetQueueDepth,omitempty"`
}

// ModelDeploymentSpec is the desired-state specification.
// +kubebuilder:object:generate=true
type ModelDeploymentSpec struct {
	// ModelRef is the model identifier: HuggingFace repo (org/model) or OCI digest.
	// Examples: "meta-llama/Llama-3.2-3B-Instruct", "ollama/llama3.2:3b"
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	ModelRef string `json:"modelRef"`

	// ServingRuntime selects the inference server backend.
	// +kubebuilder:default=ollama
	ServingRuntime ServingRuntimeType `json:"servingRuntime,omitempty"`

	// Replicas is the initial desired replica count before autoscaling takes over.
	// +kubebuilder:default=1
	// +kubebuilder:validation:Minimum=0
	Replicas *int32 `json:"replicas,omitempty"`

	// Resources sets compute requests/limits for the model server container.
	// On real GPU nodes, add nvidia.com/gpu to limits.
	Resources corev1.ResourceRequirements `json:"resources,omitempty"`

	// VaultSecretPath is the Vault KV path for model-specific secrets
	// (HuggingFace token, model API keys). Empty string disables Vault injection.
	// Example: "secret/data/inference/hf-token"
	// +kubebuilder:validation:Pattern=`^(secret/data/.*)?$`
	VaultSecretPath string `json:"vaultSecretPath,omitempty"`

	// Autoscaling configures KEDA-based horizontal scaling.
	// When set, the controller creates a ScaledObject in the same namespace.
	Autoscaling *AutoscalingConfig `json:"autoscaling,omitempty"`
}

// ModelDeploymentStatus is the observed-state report written by the reconciler.
// +kubebuilder:object:generate=true
type ModelDeploymentStatus struct {
	// Phase is the high-level lifecycle state of the ModelDeployment.
	Phase ModelDeploymentPhase `json:"phase,omitempty"`

	// ReadyReplicas is the number of pods currently passing readiness probes.
	ReadyReplicas int32 `json:"readyReplicas,omitempty"`

	// ObservedGeneration is the .metadata.generation the reconciler last acted on.
	// Used to detect whether the spec has changed since the last reconcile.
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Conditions follows the standard Kubernetes condition convention:
	// Type=Ready, Type=Progressing, Type=Degraded.
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// ModelDigest is the SHA256 digest of the model artifact pulled by the
	// serving runtime. Populated after the first successful pod startup.
	// Enables deterministic rollback: redeploy by re-pinning this digest.
	ModelDigest string `json:"modelDigest,omitempty"`

	// LastReconcileTime records when the reconciler last updated this status.
	LastReconcileTime *metav1.Time `json:"lastReconcileTime,omitempty"`
}

// ModelDeployment is the root CRD object.
//
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,categories=ai-platform,shortName=mdep
// +kubebuilder:printcolumn:name="Model",type=string,JSONPath=`.spec.modelRef`
// +kubebuilder:printcolumn:name="Runtime",type=string,JSONPath=`.spec.servingRuntime`
// +kubebuilder:printcolumn:name="Replicas",type=integer,JSONPath=`.spec.replicas`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type ModelDeployment struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ModelDeploymentSpec   `json:"spec,omitempty"`
	Status ModelDeploymentStatus `json:"status,omitempty"`
}

// ModelDeploymentList is required by controller-runtime for list operations.
// +kubebuilder:object:root=true
type ModelDeploymentList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ModelDeployment `json:"items"`
}

// DeepCopy returns a deep copy of the ModelDeployment. Required so that
// client.MergeFrom(md.DeepCopy()) resolves to *ModelDeployment (which
// implements client.Object) rather than the promoted metav1.ObjectMeta.DeepCopy()
// which returns *metav1.ObjectMeta and does not implement client.Object.
func (m *ModelDeployment) DeepCopy() *ModelDeployment {
	if m == nil {
		return nil
	}
	out := new(ModelDeployment)
	m.DeepCopyInto(out)
	return out
}

// DeepCopyObject satisfies runtime.Object. In a kubebuilder project,
// controller-gen generates this automatically. Included here for
// compilation without the generator.
func (m *ModelDeployment) DeepCopyObject() runtime.Object {
	if m == nil {
		return nil
	}
	out := new(ModelDeployment)
	m.DeepCopyInto(out)
	return out
}

func (m *ModelDeployment) DeepCopyInto(out *ModelDeployment) {
	*out = *m
	out.TypeMeta = m.TypeMeta
	m.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	m.Spec.DeepCopyInto(&out.Spec)
	m.Status.DeepCopyInto(&out.Status)
}

func (s *ModelDeploymentSpec) DeepCopyInto(out *ModelDeploymentSpec) {
	*out = *s
	s.Resources.DeepCopyInto(&out.Resources)
	if s.Replicas != nil {
		r := *s.Replicas
		out.Replicas = &r
	}
	if s.Autoscaling != nil {
		a := *s.Autoscaling
		out.Autoscaling = &a
	}
}

func (s *ModelDeploymentStatus) DeepCopyInto(out *ModelDeploymentStatus) {
	*out = *s
	if s.Conditions != nil {
		out.Conditions = make([]metav1.Condition, len(s.Conditions))
		copy(out.Conditions, s.Conditions)
	}
	if s.LastReconcileTime != nil {
		t := *s.LastReconcileTime
		out.LastReconcileTime = &t
	}
}

func (m *ModelDeploymentList) DeepCopyObject() runtime.Object {
	if m == nil {
		return nil
	}
	out := new(ModelDeploymentList)
	out.TypeMeta = m.TypeMeta
	m.ListMeta.DeepCopyInto(&out.ListMeta)
	out.Items = make([]ModelDeployment, len(m.Items))
	for i := range m.Items {
		m.Items[i].DeepCopyInto(&out.Items[i])
	}
	return out
}

// GroupVersionKind wires ModelDeployment into the Kubernetes API machinery.
var (
	GroupVersion  = schema.GroupVersion{Group: "platform.ai", Version: "v1alpha1"}
	SchemeBuilder = runtime.NewSchemeBuilder(func(s *runtime.Scheme) error {
		s.AddKnownTypes(GroupVersion,
			&ModelDeployment{},
			&ModelDeploymentList{},
		)
		metav1.AddToGroupVersion(s, GroupVersion)
		return nil
	})
	AddToScheme = SchemeBuilder.AddToScheme
)

// =============================================================================
// Reconciler
// =============================================================================
//
// The reconciler is the core of every operator. It is called by the
// controller-runtime Manager whenever the observed state of a ModelDeployment
// (or any resource it owns) diverges from the desired state in etcd.
//
// Design principles encoded here:
//   • Level-triggered: reconcile acts on the CURRENT state, not the event.
//     Two rapid spec updates collapse into one reconcile against the latest.
//   • Idempotent: safe to call any number of times with the same result.
//   • Owner references: child resources (Deployment, Service) carry an
//     OwnerReference to the ModelDeployment. When the ModelDeployment is
//     deleted, the GC cascades the delete to all owned children.
//   • Status subresource: status updates use a dedicated PATCH to avoid
//     overwriting spec changes from concurrent kubectl apply calls.

// ModelDeploymentReconciler holds the dependencies injected by the Manager.
//
// +kubebuilder:rbac:groups=platform.ai,resources=modeldeployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=platform.ai,resources=modeldeployments/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=platform.ai,resources=modeldeployments/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch
type ModelDeploymentReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// Reconcile is the entry point called by the controller-runtime work queue.
// It is guaranteed to receive the most recent version of the object after
// informer cache sync — not the version that triggered the event.
//
// Return semantics:
//
//	ctrl.Result{}                           — success, no requeue
//	ctrl.Result{RequeueAfter: d}            — success, requeue after duration d
//	ctrl.Result{Requeue: true}              — success, requeue immediately
//	error (non-nil)                         — failure, requeue with backoff
func (r *ModelDeploymentReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := ctrl.LoggerFrom(ctx)

	// ── Fetch the ModelDeployment ──────────────────────────────────────────────
	var md ModelDeployment
	if err := r.Get(ctx, req.NamespacedName, &md); err != nil {
		// NotFound means the object was deleted between the event and this
		// reconcile call. Nothing to do — owned children are GC'd via owner refs.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// ── Deletion gate — process finalizer before removal ──────────────────────
	if !md.DeletionTimestamp.IsZero() {
		return r.reconcileDelete(ctx, &md)
	}

	// ── Ensure our finalizer is present ───────────────────────────────────────
	if err := r.ensureFinalizer(ctx, &md); err != nil {
		return ctrl.Result{}, err
	}

	// ── Core reconcile path ───────────────────────────────────────────────────
	log.Info("Reconciling ModelDeployment",
		"model", md.Spec.ModelRef,
		"runtime", md.Spec.ServingRuntime,
		"generation", md.Generation,
	)

	if err := r.reconcileDeployment(ctx, &md); err != nil {
		r.setStatusPhase(ctx, &md, PhaseFailed,
			fmt.Sprintf("Deployment reconcile failed: %v", err))
		return ctrl.Result{}, err
	}

	if err := r.reconcileService(ctx, &md); err != nil {
		r.setStatusPhase(ctx, &md, PhaseFailed,
			fmt.Sprintf("Service reconcile failed: %v", err))
		return ctrl.Result{}, err
	}

	if err := r.syncStatus(ctx, &md); err != nil {
		return ctrl.Result{}, err
	}

	// Requeue every 30 seconds for drift detection. This is the safety net:
	// even if no watch event fires, we will detect and correct any out-of-band
	// changes (e.g., kubectl scale deploy --replicas=0 bypassing the operator).
	return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

// reconcileDeployment ensures a Deployment exists with the spec derived from
// the ModelDeployment. Uses CreateOrUpdate (server-side apply semantics):
//   - If Deployment does not exist → Create
//   - If Deployment exists but spec differs → Update
//   - If Deployment exists and spec matches → no-op (idempotent)
func (r *ModelDeploymentReconciler) reconcileDeployment(ctx context.Context, md *ModelDeployment) error {
	desired := r.buildDeployment(md)

	// Set owner reference so the Deployment is GC'd when ModelDeployment is deleted.
	if err := controllerutil.SetControllerReference(md, desired, r.Scheme); err != nil {
		return fmt.Errorf("set controller reference on Deployment: %w", err)
	}

	existing := &appsv1.Deployment{}
	err := r.Get(ctx, client.ObjectKeyFromObject(desired), existing)
	if errors.IsNotFound(err) {
		ctrl.LoggerFrom(ctx).Info("Creating Deployment", "name", desired.Name)
		return r.Create(ctx, desired)
	}
	if err != nil {
		return fmt.Errorf("get Deployment: %w", err)
	}

	// Merge desired spec into existing, preserving fields we don't own
	// (e.g., HPA-managed replica count when autoscaling is active).
	patch := client.MergeFrom(existing.DeepCopy())
	existing.Spec.Template = desired.Spec.Template
	existing.Spec.Selector = desired.Spec.Selector
	if md.Spec.Autoscaling == nil {
		// Only stomp replicas when NOT autoscaling — KEDA owns them otherwise.
		existing.Spec.Replicas = desired.Spec.Replicas
	}
	return r.Patch(ctx, existing, patch)
}

// reconcileService ensures a ClusterIP Service exposes the model server.
func (r *ModelDeploymentReconciler) reconcileService(ctx context.Context, md *ModelDeployment) error {
	desired := r.buildService(md)

	if err := controllerutil.SetControllerReference(md, desired, r.Scheme); err != nil {
		return fmt.Errorf("set controller reference on Service: %w", err)
	}

	existing := &corev1.Service{}
	err := r.Get(ctx, client.ObjectKeyFromObject(desired), existing)
	if errors.IsNotFound(err) {
		ctrl.LoggerFrom(ctx).Info("Creating Service", "name", desired.Name)
		return r.Create(ctx, desired)
	}
	if err != nil {
		return fmt.Errorf("get Service: %w", err)
	}

	patch := client.MergeFrom(existing.DeepCopy())
	existing.Spec.Ports = desired.Spec.Ports
	existing.Spec.Selector = desired.Spec.Selector
	return r.Patch(ctx, existing, patch)
}

// syncStatus reads the current state of the owned Deployment and updates
// ModelDeployment.Status accordingly. Uses a dedicated status subresource
// PATCH to avoid optimistic lock conflicts with spec updates.
func (r *ModelDeploymentReconciler) syncStatus(ctx context.Context, md *ModelDeployment) error {
	var deploy appsv1.Deployment
	err := r.Get(ctx, client.ObjectKey{
		Namespace: md.Namespace,
		Name:      deploymentName(md),
	}, &deploy)
	if err != nil {
		return client.IgnoreNotFound(err)
	}

	patch := client.MergeFrom(md.DeepCopy())

	md.Status.ReadyReplicas = deploy.Status.ReadyReplicas
	md.Status.ObservedGeneration = md.Generation
	now := metav1.Now()
	md.Status.LastReconcileTime = &now

	// Spec.Replicas may be nil when KEDA owns replica count management.
	// In that case we skip the desired-vs-ready comparison and reflect only
	// the observed Deployment status, avoiding a nil pointer dereference.
	specReplicas := int32(1)
	if md.Spec.Replicas != nil {
		specReplicas = *md.Spec.Replicas
	}

	switch {
	case deploy.Status.ReadyReplicas == 0 && deploy.Status.Replicas > 0:
		md.Status.Phase = PhasePending
		r.setStatusCondition(md, "Ready", metav1.ConditionFalse,
			"Progressing", "Waiting for pods to become ready")
	case md.Spec.Replicas != nil && *md.Spec.Replicas != deploy.Status.ReadyReplicas:
		md.Status.Phase = PhaseScaling
		r.setStatusCondition(md, "Ready", metav1.ConditionFalse,
			"Scaling", fmt.Sprintf("Ready %d/%d", deploy.Status.ReadyReplicas, specReplicas))
	case deploy.Status.ReadyReplicas > 0:
		md.Status.Phase = PhaseRunning
		r.setStatusCondition(md, "Ready", metav1.ConditionTrue,
			"AllReplicasReady", fmt.Sprintf("%d/%d replicas ready", deploy.Status.ReadyReplicas, specReplicas))
	}

	return r.Status().Patch(ctx, md, patch)
}

// reconcileDelete runs cleanup logic when a ModelDeployment has a non-zero
// DeletionTimestamp (kubectl delete was called). Finalizers block the actual
// deletion until this returns nil.
//
// In a production operator this is where you would:
//   - Drain in-flight requests by waiting for queue depth to reach zero
//   - Unregister the model from a model registry
//   - Emit a deletion audit event to SIEM
func (r *ModelDeploymentReconciler) reconcileDelete(ctx context.Context, md *ModelDeployment) (ctrl.Result, error) {
	log := ctrl.LoggerFrom(ctx)

	if !controllerutil.ContainsFinalizer(md, ModelDeploymentFinalizer) {
		return ctrl.Result{}, nil
	}

	log.Info("Running pre-delete cleanup", "model", md.Spec.ModelRef)

	// ── Pre-delete cleanup ────────────────────────────────────────────────────
	// Owned Deployment and Service will be GC'd by Kubernetes after finalizer
	// removal — no manual delete needed here. This block is for external cleanup
	// (model registry deregistration, PVC cleanup, etc.).

	// Remove the finalizer to unblock the GC cascade.
	patch := client.MergeFrom(md.DeepCopy())
	controllerutil.RemoveFinalizer(md, ModelDeploymentFinalizer)
	if err := r.Patch(ctx, md, patch); err != nil {
		return ctrl.Result{}, fmt.Errorf("remove finalizer: %w", err)
	}

	log.Info("Finalizer removed — deletion will proceed", "model", md.Spec.ModelRef)
	return ctrl.Result{}, nil
}

// ensureFinalizer adds the operator finalizer if it is not already present.
// Must be called before any mutation logic so cleanup always runs on delete.
func (r *ModelDeploymentReconciler) ensureFinalizer(ctx context.Context, md *ModelDeployment) error {
	if controllerutil.ContainsFinalizer(md, ModelDeploymentFinalizer) {
		return nil
	}
	patch := client.MergeFrom(md.DeepCopy())
	controllerutil.AddFinalizer(md, ModelDeploymentFinalizer)
	return r.Patch(ctx, md, patch)
}

// setStatusCondition upserts a metav1.Condition on the ModelDeployment status.
// Follows the Kubernetes condition API conventions:
//   - Type (string)  : machine-readable condition name (e.g., "Ready")
//   - Status         : True / False / Unknown
//   - Reason         : CamelCase, non-empty, machine-readable
//   - Message        : human-readable, may be empty
func (r *ModelDeploymentReconciler) setStatusCondition(
	md *ModelDeployment,
	condType string,
	status metav1.ConditionStatus,
	reason, message string,
) {
	now := metav1.Now()
	for i, c := range md.Status.Conditions {
		if c.Type == condType {
			if c.Status == status && c.Reason == reason {
				return // No change — avoid noisy LastTransitionTime churn
			}
			md.Status.Conditions[i] = metav1.Condition{
				Type:               condType,
				Status:             status,
				Reason:             reason,
				Message:            message,
				LastTransitionTime: now,
				ObservedGeneration: md.Generation,
			}
			return
		}
	}
	md.Status.Conditions = append(md.Status.Conditions, metav1.Condition{
		Type:               condType,
		Status:             status,
		Reason:             reason,
		Message:            message,
		LastTransitionTime: now,
		ObservedGeneration: md.Generation,
	})
}

func (r *ModelDeploymentReconciler) setStatusPhase(
	ctx context.Context,
	md *ModelDeployment,
	phase ModelDeploymentPhase,
	message string,
) {
	patch := client.MergeFrom(md.DeepCopy())
	md.Status.Phase = phase
	now := metav1.Now()
	md.Status.LastReconcileTime = &now
	_ = r.Status().Patch(ctx, md, patch)
}

// =============================================================================
// Builder helpers — translate ModelDeploymentSpec → Kubernetes objects
// =============================================================================

// buildDeployment constructs the desired appsv1.Deployment for a ModelDeployment.
// Container image is selected based on ServingRuntime. Resource defaults are
// applied for Apple Silicon / CPU-only Kind clusters; override via .spec.resources.
func (r *ModelDeploymentReconciler) buildDeployment(md *ModelDeployment) *appsv1.Deployment {
	labels := labelsForModel(md)
	replicas := int32(1)
	if md.Spec.Replicas != nil {
		replicas = *md.Spec.Replicas
	}

	container := corev1.Container{
		Name:  "model-server",
		Image: imageForRuntime(md.Spec.ServingRuntime, md.Spec.ModelRef),
		Ports: []corev1.ContainerPort{
			{Name: "http", ContainerPort: portForRuntime(md.Spec.ServingRuntime), Protocol: corev1.ProtocolTCP},
			{Name: "metrics", ContainerPort: 9400, Protocol: corev1.ProtocolTCP},
		},
		Env: []corev1.EnvVar{
			{Name: "MODEL_NAME", Value: md.Spec.ModelRef},
		},
		Resources: defaultResourcesIfEmpty(md.Spec.Resources),
		ReadinessProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				HTTPGet: &corev1.HTTPGetAction{
					Path: healthPathForRuntime(md.Spec.ServingRuntime),
					Port: intstr.FromString("http"),
				},
			},
			InitialDelaySeconds: 30,
			PeriodSeconds:       10,
			FailureThreshold:    6,
		},
		LivenessProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				HTTPGet: &corev1.HTTPGetAction{
					Path: healthPathForRuntime(md.Spec.ServingRuntime),
					Port: intstr.FromString("http"),
				},
			},
			InitialDelaySeconds: 60,
			PeriodSeconds:       15,
			FailureThreshold:    3,
		},
		// CKS: Run as non-root, drop all capabilities, read-only root filesystem.
		SecurityContext: &corev1.SecurityContext{
			AllowPrivilegeEscalation: boolPtr(false),
			ReadOnlyRootFilesystem:   boolPtr(true),
			RunAsNonRoot:             boolPtr(true),
			RunAsUser:                int64Ptr(1000),
			Capabilities: &corev1.Capabilities{
				Drop: []corev1.Capability{"ALL"},
			},
		},
		// Vault Agent writes secrets to /vault/secrets/ via a shared tmpfs volume.
		VolumeMounts: []corev1.VolumeMount{
			{Name: "vault-secrets", MountPath: "/vault/secrets", ReadOnly: true},
			{Name: "tmp", MountPath: "/tmp"},
		},
	}

	podLabels := make(map[string]string, len(labels)+1)
	for k, v := range labels {
		podLabels[k] = v
	}
	podLabels["platform.ai/scrape"] = "true" // Allow Prometheus scrape per NetworkPolicy 7

	// Vault Agent annotation injection (when VaultSecretPath is configured).
	podAnnotations := map[string]string{}
	if md.Spec.VaultSecretPath != "" {
		podAnnotations["vault.hashicorp.com/agent-inject"] = "true"
		podAnnotations["vault.hashicorp.com/role"] = "inference-role"
		podAnnotations["vault.hashicorp.com/agent-inject-secret-config"] = md.Spec.VaultSecretPath
		podLabels["vault-agent"] = "true" // Required by NetworkPolicy 5
	}

	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      deploymentName(md),
			Namespace: md.Namespace,
			Labels:    labels,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Strategy: appsv1.DeploymentStrategy{
				// RollingUpdate ensures zero-downtime model swaps:
				// MaxSurge=1 keeps one extra pod running during rollout.
				// MaxUnavailable=0 prevents dropping below desired capacity.
				Type: appsv1.RollingUpdateDeploymentStrategyType,
				RollingUpdate: &appsv1.RollingUpdateDeployment{
					MaxSurge:       intStrPtr(intstr.FromInt32(1)),
					MaxUnavailable: intStrPtr(intstr.FromInt32(0)),
				},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels:      podLabels,
					Annotations: podAnnotations,
				},
				Spec: corev1.PodSpec{
					ServiceAccountName: "inference-sa",
					SecurityContext: &corev1.PodSecurityContext{
						RunAsNonRoot: boolPtr(true),
						SeccompProfile: &corev1.SeccompProfile{
							Type: corev1.SeccompProfileTypeRuntimeDefault,
						},
					},
					Containers: []corev1.Container{container},
					Volumes: []corev1.Volume{
						{
							Name: "vault-secrets",
							VolumeSource: corev1.VolumeSource{
								EmptyDir: &corev1.EmptyDirVolumeSource{
									Medium: corev1.StorageMediumMemory, // tmpfs — never hits disk
								},
							},
						},
						{
							Name: "tmp",
							VolumeSource: corev1.VolumeSource{
								EmptyDir: &corev1.EmptyDirVolumeSource{},
							},
						},
					},
					// Node affinity: prefer inference-class nodes (GPU nodes in production).
					// Tolerates CPU-only nodes for Kind/dev — remove for production clusters.
					Affinity: &corev1.Affinity{
						NodeAffinity: &corev1.NodeAffinity{
							PreferredDuringSchedulingIgnoredDuringExecution: []corev1.PreferredSchedulingTerm{
								{
									Weight: 100,
									Preference: corev1.NodeSelectorTerm{
										MatchExpressions: []corev1.NodeSelectorRequirement{
											{
												Key:      "platform.ai/node-class",
												Operator: corev1.NodeSelectorOpIn,
												Values:   []string{"inference"},
											},
										},
									},
								},
							},
						},
					},
				},
			},
		},
	}
}

// buildService creates a ClusterIP Service for the model server.
// Named port "http" is the inference API; "metrics" exposes Prometheus.
func (r *ModelDeploymentReconciler) buildService(md *ModelDeployment) *corev1.Service {
	labels := labelsForModel(md)
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      serviceName(md),
			Namespace: md.Namespace,
			Labels:    labels,
			Annotations: map[string]string{
				"prometheus.io/scrape": "true",
				"prometheus.io/port":   "9400",
				"prometheus.io/path":   "/metrics",
			},
		},
		Spec: corev1.ServiceSpec{
			Type:     corev1.ServiceTypeClusterIP,
			Selector: labels,
			Ports: []corev1.ServicePort{
				{
					Name:       "http",
					Port:       portForRuntime(md.Spec.ServingRuntime),
					TargetPort: intstr.FromString("http"),
					Protocol:   corev1.ProtocolTCP,
				},
				{
					Name:       "metrics",
					Port:       9400,
					TargetPort: intstr.FromInt32(9400),
					Protocol:   corev1.ProtocolTCP,
				},
			},
		},
	}
}

// =============================================================================
// Utility helpers
// =============================================================================

func deploymentName(md *ModelDeployment) string { return md.Name + "-server" }
func serviceName(md *ModelDeployment) string    { return md.Name + "-svc" }

func labelsForModel(md *ModelDeployment) map[string]string {
	return map[string]string{
		"app":                          md.Name,
		"app.kubernetes.io/name":       md.Name,
		"app.kubernetes.io/component":  "model-server",
		"app.kubernetes.io/managed-by": "modeldeployment-operator",
		"platform.ai/serving-runtime":  string(md.Spec.ServingRuntime),
	}
}

func imageForRuntime(rt ServingRuntimeType, modelRef string) string {
	switch rt {
	case ServingRuntimeOllama:
		return "ollama/ollama:0.3.6"
	case ServingRuntimeVLLM:
		return "vllm/vllm-openai:v0.6.3"
	case ServingRuntimeTriton:
		// NOTE: nvcr.io/nvidia/tritonserver has no official ARM64 image.
		// On Apple Silicon M4 / Kind/OrbStack: add --platform linux/amd64 to docker pull
		// for Rosetta 2 emulation (expect 15-30% overhead; benchmarks not portable).
		// For local M4 dev, use Ollama instead and swap to Triton only on real GPU nodes.
		return "nvcr.io/nvidia/tritonserver:24.10-py3"
	default:
		return "ollama/ollama:latest"
	}
}

func portForRuntime(rt ServingRuntimeType) int32 {
	switch rt {
	case ServingRuntimeOllama:
		return 11434
	case ServingRuntimeVLLM:
		return 8000
	case ServingRuntimeTriton:
		return 8000
	default:
		return 11434
	}
}

func healthPathForRuntime(rt ServingRuntimeType) string {
	switch rt {
	case ServingRuntimeOllama:
		return "/api/version"
	case ServingRuntimeVLLM:
		return "/health"
	case ServingRuntimeTriton:
		return "/v2/health/ready"
	default:
		return "/health"
	}
}

func defaultResourcesIfEmpty(r corev1.ResourceRequirements) corev1.ResourceRequirements {
	if r.Requests != nil || r.Limits != nil {
		return r
	}
	// Conservative defaults for Kind/Apple Silicon dev clusters.
	// For production GPU nodes, set nvidia.com/gpu: "1" in limits.
	return corev1.ResourceRequirements{
		Requests: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("500m"),
			corev1.ResourceMemory: resource.MustParse("1Gi"),
		},
		Limits: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("2"),
			corev1.ResourceMemory: resource.MustParse("4Gi"),
		},
	}
}

func boolPtr(b bool) *bool                               { return &b }
func int64Ptr(i int64) *int64                            { return &i }
func intStrPtr(i intstr.IntOrString) *intstr.IntOrString { return &i }

// SetupWithManager wires the reconciler into the controller-runtime Manager.
//
// Key decisions:
//
//	For(ModelDeployment)    — watch the primary resource (triggers on any change)
//	Owns(Deployment)        — watch owned Deployments (pod restart → reconcile)
//	Owns(Service)           — watch owned Services
//	GenerationChangedPredicate — filter out status-only updates to avoid reconcile
//	                            storms when we ourselves update .status. Without
//	                            this, every status PATCH would trigger a new
//	                            reconcile, causing infinite loops.
func (r *ModelDeploymentReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&ModelDeployment{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		WithEventFilter(predicate.GenerationChangedPredicate{}).
		Complete(r)
}

// =============================================================================
// main() — Manager bootstrap
// =============================================================================
//
// The Manager is the process-level singleton that:
//   1. Creates and wires the controller-runtime informer/cache
//   2. Starts all registered controllers (reconcilers)
//   3. Manages leader election (active/standby HA for the operator pod)
//   4. Exposes /healthz and /readyz HTTP probes
//   5. Exposes /metrics for operator telemetry (controller-runtime default)
//   6. Handles OS signals for graceful shutdown (SIGTERM → drain queue)

func main() {
	// ── Logger setup ──────────────────────────────────────────────────────────
	// zap is the controller-runtime default. JSON format for structured logging
	// in production; console format in dev (detected by TTY).
	opts := zap.Options{Development: false}
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	setupLog := ctrl.Log.WithName("setup")

	// ── Scheme registration ───────────────────────────────────────────────────
	// The scheme maps GVK (Group/Version/Kind) strings → Go types.
	// client-go scheme covers built-in K8s types (Deployment, Service, etc.).
	// AddToScheme registers our custom ModelDeployment type.
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		setupLog.Error(err, "Failed to add client-go scheme")
		os.Exit(1)
	}
	if err := AddToScheme(scheme); err != nil {
		setupLog.Error(err, "Failed to add ModelDeployment scheme")
		os.Exit(1)
	}

	// ── Manager construction ──────────────────────────────────────────────────
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: scheme,

		// Metrics server — controller-runtime exposes Go runtime + reconcile
		// latency histograms on :8080/metrics by default.
		// Bind to 127.0.0.1 in dev; 0.0.0.0 when running in-cluster with a
		// Prometheus ServiceMonitor scraping the operator pod.
		// MetricsBindAddress: ":8080",

		// Health probe server — used by Deployment readiness/liveness probes.
		HealthProbeBindAddress: ":8081",

		// Leader election prevents split-brain when multiple operator replicas
		// are running (e.g., during a rolling update). The active replica holds
		// the Lease; standby replicas block in the election loop.
		// ID format: <resource>.<group> — must be unique per operator in a cluster.
		LeaderElection:          true,
		LeaderElectionID:        "modeldeployment.platform.ai",
		LeaderElectionNamespace: "inference", // Scope to inference ns (least privilege)
	})
	if err != nil {
		setupLog.Error(err, "Failed to create manager")
		os.Exit(1)
	}

	// ── Register reconciler ───────────────────────────────────────────────────
	if err := (&ModelDeploymentReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "Failed to setup ModelDeployment controller")
		os.Exit(1)
	}

	// ── Health checks ─────────────────────────────────────────────────────────
	// /healthz: liveness — always returns 200 once the manager is running.
	// /readyz:  readiness — returns 200 only after the informer cache has synced
	//           (i.e., the operator has observed the full current cluster state).
	//           Without cache sync, reconciles may act on stale data.
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "Failed to add healthz check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "Failed to add readyz check")
		os.Exit(1)
	}

	// ── Start ─────────────────────────────────────────────────────────────────
	// ctrl.SetupSignalHandler() returns a context that is cancelled on SIGTERM/
	// SIGINT. mgr.Start() blocks until that context is done, draining the work
	// queue gracefully before returning.
	setupLog.Info("Starting ModelDeployment operator",
		"leader-election", true,
		"health-probe-addr", ":8081",
	)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "Manager exited with error")
		os.Exit(1)
	}
}
