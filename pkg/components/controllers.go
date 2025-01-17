package components

import (
	"context"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	operatorv1 "github.com/openshift/api/operator/v1"
	"github.com/openshift/microshift/pkg/assets"
	"github.com/openshift/microshift/pkg/config"
	"github.com/openshift/microshift/pkg/util/cryptomaterial"
	"k8s.io/klog/v2"
)

const (
	haproxyMaxTimeoutMilliseconds = 2147483647 * time.Millisecond
)

func startServiceCAController(ctx context.Context, cfg *config.Config, kubeconfigPath string) error {
	var (
		//TODO: fix the rolebinding and sa
		clusterRoleBinding = []string{
			"components/service-ca/clusterrolebinding.yaml",
		}
		clusterRole = []string{
			"components/service-ca/clusterrole.yaml",
		}
		roleBinding = []string{
			"components/service-ca/rolebinding.yaml",
		}
		role = []string{
			"components/service-ca/role.yaml",
		}
		apps = []string{
			"components/service-ca/deployment.yaml",
		}
		ns = []string{
			"components/service-ca/ns.yaml",
		}
		sa = []string{
			"components/service-ca/sa.yaml",
		}
		secret     = "components/service-ca/signing-secret.yaml"
		secretName = "signing-key"
		cm         = "components/service-ca/signing-cabundle.yaml"
		cmName     = "signing-cabundle"
	)

	serviceCADir := cryptomaterial.ServiceCADir(cryptomaterial.CertsDirectory(config.DataDir))
	caCertPath := cryptomaterial.CACertPath(serviceCADir)
	caKeyPath := cryptomaterial.CAKeyPath(serviceCADir)

	cmData := map[string]string{}
	secretData := map[string][]byte{}

	caCertPEM, err := os.ReadFile(caCertPath)
	if err != nil {
		return err
	}
	caKeyPEM, err := os.ReadFile(caKeyPath)
	if err != nil {
		return err
	}
	cmData["ca-bundle.crt"] = string(caCertPEM)
	secretData["tls.crt"] = caCertPEM
	secretData["tls.key"] = caKeyPEM

	if err := assets.ApplyNamespaces(ctx, ns, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply ns %v: %v", ns, err)
		return err
	}
	if err := assets.ApplyClusterRoleBindings(ctx, clusterRoleBinding, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply clusterRolebinding %v: %v", clusterRoleBinding, err)
		return err
	}
	if err := assets.ApplyClusterRoles(ctx, clusterRole, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply clusterRole %v: %v", clusterRole, err)
		return err
	}
	if err := assets.ApplyRoleBindings(ctx, roleBinding, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply rolebinding %v: %v", roleBinding, err)
		return err
	}
	if err := assets.ApplyRoles(ctx, role, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply role %v: %v", role, err)
		return err
	}
	if err := assets.ApplyServiceAccounts(ctx, sa, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply sa %v: %v", sa, err)
		return err
	}
	if err := assets.ApplySecretWithData(ctx, secret, secretData, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply secret %v: %v", secret, err)
		return err
	}
	if err := assets.ApplyConfigMapWithData(ctx, cm, cmData, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply configMap %v: %v", cm, err)
		return err
	}
	extraParams := assets.RenderParams{
		"CAConfigMap": cmName,
		"TLSSecret":   secretName,
	}
	if err := assets.ApplyDeployments(ctx, apps, renderTemplate, renderParamsFromConfig(cfg, extraParams), kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply apps %v: %v", apps, err)
		return err
	}
	return nil
}

func startIngressController(ctx context.Context, cfg *config.Config, kubeconfigPath string) error {
	var (
		clusterRoleBinding = []string{
			"components/openshift-router/cluster-role-binding.yaml",
		}
		clusterRole = []string{
			"components/openshift-router/cluster-role.yaml",
			"components/openshift-router/cluster-role-aggregate-edit-route.yaml",
			"components/openshift-router/cluster-role-aggregate-admin-route.yaml",
			"components/openshift-router/cluster-role-system-router.yaml",
		}
		apps = []string{
			"components/openshift-router/deployment.yaml",
		}
		ns = []string{
			"components/openshift-router/namespace.yaml",
		}
		sa = []string{
			"components/openshift-router/service-account.yaml",
		}
		svc = []string{
			"components/openshift-router/service-internal.yaml",
			"components/openshift-router/service-cloud.yaml",
		}
		cm                   = "components/openshift-router/configmap.yaml"
		servingKeypairSecret = "components/openshift-router/serving-certificate.yaml"
	)

	if cfg.Ingress.Status == config.StatusRemoved {
		if err := assets.DeleteClusterRoleBindings(ctx, clusterRoleBinding, kubeconfigPath); err != nil {
			klog.Warningf("Failed to delete cluster role bindings %v: %v", clusterRoleBinding, err)
			return err
		}
		if err := assets.DeleteClusterRoles(ctx, clusterRole, kubeconfigPath); err != nil {
			klog.Warningf("Failed to delete cluster roles %v: %v", clusterRole, err)
			return err
		}
		if err := assets.DeleteNamespaces(ctx, ns, kubeconfigPath); err != nil {
			klog.Warningf("Failed to delete namespaces %v: %v", ns, err)
			return err
		}
		return nil
	}

	if err := assets.ApplyNamespaces(ctx, ns, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply namespaces %v: %v", ns, err)
		return err
	}
	if err := assets.ApplyClusterRoles(ctx, clusterRole, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply clusterRole %v: %v", clusterRole, err)
		return err
	}
	if err := assets.ApplyClusterRoleBindings(ctx, clusterRoleBinding, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply clusterRolebinding %v: %v", clusterRoleBinding, err)
		return err
	}
	if err := assets.ApplyServiceAccounts(ctx, sa, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply serviceAccount %v %v", sa, err)
		return err
	}

	serviceCADir := cryptomaterial.ServiceCADir(cryptomaterial.CertsDirectory(config.DataDir))
	caCertPath := cryptomaterial.CACertPath(serviceCADir)
	cmData := map[string]string{}

	caCertPEM, err := os.ReadFile(caCertPath)
	if err != nil {
		return err
	}
	cmData["service-ca.crt"] = string(caCertPEM)

	if err := assets.ApplyConfigMapWithData(ctx, cm, cmData, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply configMap %v: %v", cm, err)
		return err
	}

	extraParams := generateIngressParams(cfg)

	if err := assets.ApplyServices(ctx, svc, renderTemplate, renderParamsFromConfig(cfg, extraParams), kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply service %v %v", svc, err)
		return err
	}
	if err := assets.ApplySecretWithData(
		ctx,
		servingKeypairSecret,
		map[string][]byte{
			"tls.crt": cfg.Ingress.ServingCertificate,
			"tls.key": cfg.Ingress.ServingKey,
		},
		kubeconfigPath,
	); err != nil {
		klog.Warningf("failed to apply secret %q: %v", servingKeypairSecret, err)
		return err
	}

	if err := assets.ApplyDeployments(ctx, apps, renderTemplate, renderParamsFromConfig(cfg, extraParams), kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply apps %v: %v", apps, err)
		return err
	}
	return nil
}

func startDNSController(ctx context.Context, cfg *config.Config, kubeconfigPath string) error {
	var (
		clusterRoleBinding = []string{
			"components/openshift-dns/dns/cluster-role-binding.yaml",
		}
		clusterRole = []string{
			"components/openshift-dns/dns/cluster-role.yaml",
		}
		apps = []string{
			"components/openshift-dns/dns/daemonset.yaml",
			"components/openshift-dns/node-resolver/daemonset.yaml",
		}
		ns = []string{
			"components/openshift-dns/dns/namespace.yaml",
		}
		sa = []string{
			"components/openshift-dns/dns/service-account.yaml",
			"components/openshift-dns/node-resolver/service-account.yaml",
		}
		cm = []string{
			"components/openshift-dns/dns/configmap.yaml",
		}
		svc = []string{
			"components/openshift-dns/dns/service.yaml",
		}
	)
	if err := assets.ApplyNamespaces(ctx, ns, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply namespace %q due to error %v", ns, err)
		return err
	}

	extraParams := assets.RenderParams{
		"ClusterIP": cfg.Network.DNS,
	}
	if err := assets.ApplyServices(ctx, svc, renderTemplate, renderParamsFromConfig(cfg, extraParams), kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply service %v %v", svc, err)
		// service already created by coreDNS, not re-create it.
		return nil
	}
	if err := assets.ApplyClusterRoles(ctx, clusterRole, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply clusterRole %v %v", clusterRole, err)
		return err
	}
	if err := assets.ApplyClusterRoleBindings(ctx, clusterRoleBinding, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply clusterRoleBinding %v %v", clusterRoleBinding, err)
		return err
	}
	if err := assets.ApplyServiceAccounts(ctx, sa, kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply serviceAccount %v %v", sa, err)
		return err
	}
	if err := assets.ApplyConfigMaps(ctx, cm, renderTemplate, renderParamsFromConfig(cfg, extraParams), kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply configMap %v %v", cm, err)
		return err
	}
	if err := assets.ApplyDaemonSets(ctx, apps, renderTemplate, renderParamsFromConfig(cfg, extraParams), kubeconfigPath); err != nil {
		klog.Warningf("Failed to apply apps %v %v", apps, err)
		return err
	}
	return nil
}

// getMIMETypes returns a slice of strings from an array of operatorv1.CompressionMIMETypes.
// MIME strings that contain spaces must be quoted, as HAProxy requires a space-delimited MIME
// type list. Also quote/escape any characters that are special to HAProxy (\,', and ").
// See http://cbonte.github.io/haproxy-dconv/2.2/configuration.html#2.2
func getMIMETypes(mimeTypes []operatorv1.CompressionMIMEType) []string {
	mimes := []string{}

	for _, m := range mimeTypes {
		mimeType := string(m)
		if strings.ContainsAny(mimeType, ` \"`) {
			mimeType = strconv.Quote(mimeType)
		}
		// A single quote doesn't get escaped by strconv.Quote, so do it explicitly
		if strings.Contains(mimeType, "'") {
			mimeType = strings.ReplaceAll(mimeType, "'", "\\'")
		}
		mimes = append(mimes, mimeType)
	}

	return mimes
}

// durationToHAProxyTimespec converts a time.Duration into a number that
// HAProxy can consume, in the simplest unit possible. If the value would be
// truncated by being converted to milliseconds, it outputs in microseconds, or
// if the value would be truncated by being converted to seconds, it outputs in
// milliseconds, otherwise if the value wouldn't be truncated by converting to
// seconds, but would be if converted to minutes, it outputs in seconds, etc.
// up to a maximum unit in hours (the largest time unit natively supported by
// time.Duration).
//
// Also truncates values to the maximum length HAProxy allows if the value is
// too large, and truncates values to 0s if they are less than 0.
func durationToHAProxyTimespec(duration time.Duration) string {
	if duration <= 0 {
		return "0s"
	}
	if duration > haproxyMaxTimeoutMilliseconds {
		klog.Warningf("time value %v exceeds the maximum timeout length of %v; truncating to maximum value", duration, haproxyMaxTimeoutMilliseconds)
		return "2147483647ms"
	}

	if us := duration.Microseconds(); us%1000 != 0 {
		return fmt.Sprintf("%dus", us)
	}

	if ms := duration.Milliseconds(); ms%1000 != 0 {
		return fmt.Sprintf("%dms", ms)
	} else if ms%time.Minute.Milliseconds() != 0 {
		return fmt.Sprintf("%ds", int(math.Round(duration.Seconds())))
	} else if ms%time.Hour.Milliseconds() != 0 {
		return fmt.Sprintf("%dm", int(math.Round(duration.Minutes())))
	} else {
		return fmt.Sprintf("%dh", int(math.Round(duration.Hours())))
	}
}

func generateIngressParams(cfg *config.Config) assets.RenderParams {
	routerMode := "v4"
	if cfg.IsIPv6() {
		routerMode = "v4v6"
		if !cfg.IsIPv4() {
			routerMode = "v6"
		}
	}

	routerEnableCompression := "false"
	routerCompressionMime := ""
	if len(cfg.Ingress.HTTPCompressionPolicy.MimeTypes) > 0 {
		routerEnableCompression = "true"
		routerCompressionMime = strings.Join(getMIMETypes(cfg.Ingress.HTTPCompressionPolicy.MimeTypes), " ")
	}

	routerDisableHttp2 := true
	if cfg.Ingress.DefaultHttpVersionPolicy == config.DefaultHttpVersionV2 {
		routerDisableHttp2 = false
	}

	LogEmptyRequests := false
	if cfg.Ingress.LogEmptyRequests == operatorv1.LoggingPolicyIgnore {
		LogEmptyRequests = true
	}

	HTTPEmptyRequestsPolicy := false
	if cfg.Ingress.HTTPEmptyRequestsPolicy == operatorv1.HTTPEmptyRequestsPolicyIgnore {
		HTTPEmptyRequestsPolicy = true
	}

	extraParams := assets.RenderParams{
		"RouterNamespaceOwnership":    cfg.Ingress.AdmissionPolicy.NamespaceOwnership == config.NamespaceOwnershipAllowed,
		"RouterHttpPort":              *cfg.Ingress.Ports.Http,
		"RouterHttpsPort":             *cfg.Ingress.Ports.Https,
		"RouterMode":                  routerMode,
		"RouterBufSize":               &cfg.Ingress.TuningOptions.HeaderBufferBytes,
		"HeaderBufferMaxRewriteBytes": &cfg.Ingress.TuningOptions.HeaderBufferMaxRewriteBytes,
		"HealthCheckInterval":         durationToHAProxyTimespec(cfg.Ingress.TuningOptions.HealthCheckInterval.Duration),
		"ClientTimeout":               durationToHAProxyTimespec(cfg.Ingress.TuningOptions.ClientTimeout.Duration),
		"ClientFinTimeout":            durationToHAProxyTimespec(cfg.Ingress.TuningOptions.ClientFinTimeout.Duration),
		"ServerTimeout":               durationToHAProxyTimespec(cfg.Ingress.TuningOptions.ServerTimeout.Duration),
		"ServerFinTimeout":            durationToHAProxyTimespec(cfg.Ingress.TuningOptions.ServerFinTimeout.Duration),
		"TunnelTimeout":               durationToHAProxyTimespec(cfg.Ingress.TuningOptions.TunnelTimeout.Duration),
		"TlsInspectDelay":             durationToHAProxyTimespec(cfg.Ingress.TuningOptions.TLSInspectDelay.Duration),
		"ThreadCount":                 &cfg.Ingress.TuningOptions.ThreadCount,
		"MaxConnections":              &cfg.Ingress.TuningOptions.MaxConnections,
		"LogEmptyRequests":            LogEmptyRequests,
		"ForwardedHeaderPolicy":       &cfg.Ingress.ForwardedHeaderPolicy,
		"HTTPEmptyRequestsPolicy":     HTTPEmptyRequestsPolicy,
		"RouterEnableCompression":     routerEnableCompression,
		"RouterCompressionMime":       routerCompressionMime,
		"RouterDisableHttp2":          routerDisableHttp2,
	}

	return extraParams
}
