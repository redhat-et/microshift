/*
Copyright © 2021 Microshift Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package node

import (
	"context"
	"path/filepath"
	"strconv"

	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/openshift/microshift/pkg/config"
	"github.com/openshift/microshift/pkg/util"

	utilfeature "k8s.io/apiserver/pkg/util/feature"
	cliflag "k8s.io/component-base/cli/flag"
	kubeproxy "k8s.io/kubernetes/cmd/kube-proxy/app"
	kubelet "k8s.io/kubernetes/cmd/kubelet/app"

	kubeletoptions "k8s.io/kubernetes/cmd/kubelet/app/options"
	kubeletconfig "k8s.io/kubernetes/pkg/kubelet/apis/config"
)

const (
	// Kubelet component name
	componentKubelet = "kubelet"
)

type KubeletServer struct {
	kubeletflags *kubeletoptions.KubeletFlags
	kubeconfig   *kubeletconfig.KubeletConfiguration
}

func NewKubeletServer(cfg *config.MicroshiftConfig) *KubeletServer {
	s := &KubeletServer{}
	s.configure(cfg)
	return s
}

func (s *KubeletServer) Name() string           { return componentKubelet }
func (s *KubeletServer) Dependencies() []string { return []string{"kube-apiserver"} }

func (s *KubeletServer) configure(cfg *config.MicroshiftConfig) error {

	//create KubeletConfiguration file at cfg.DataDir + "/resources/kubelet/config/config.yaml
	if err := config.KubeletConfig(cfg); err != nil {
		logrus.Infof("Failed to create a new kubelet configuration: %v", err)
		return err
	}
	// Prepare commandline args
	args := []string{
		"--config=" + cfg.DataDir + "/resources/kubelet/config/config.yaml",
		"--bootstrap-kubeconfig=" + cfg.DataDir + "/resources/kubelet/kubeconfig",
		"--kubeconfig=" + cfg.DataDir + "/resources/kubelet/kubeconfig",
		"--container-runtime=remote",
		"--container-runtime-endpoint=unix:///var/run/crio/crio.sock",
		"--runtime-cgroups=/system.slice/crio.service",
		"--cgroup-driver=systemd",
		"--node-ip=" + cfg.NodeIP,
		"--volume-plugin-dir=" + cfg.DataDir + "/kubelet-plugins/volume/exec",
		"--logtostderr=" + strconv.FormatBool(cfg.LogDir == "" || cfg.LogAlsotostderr),
		"--alsologtostderr=" + strconv.FormatBool(cfg.LogAlsotostderr),
		"--v=" + strconv.Itoa(cfg.LogVLevel),
		"--vmodule=" + cfg.LogVModule,
	}
	if cfg.LogDir != "" {
		args = append(args, "--log-file="+filepath.Join(cfg.LogDir, "kubelet.log"))
	}
	cleanFlagSet := pflag.NewFlagSet(componentKubelet, pflag.ContinueOnError)
	cleanFlagSet.SetNormalizeFunc(cliflag.WordSepNormalizeFunc)

	kubeletFlags := kubeletoptions.NewKubeletFlags()
	kubeletConfig, err := kubeletoptions.NewKubeletConfiguration()
	// programmer error
	if err != nil {
		logrus.Fatalf("programmer error %v", err)
	}

	cmd := &cobra.Command{
		Use:          componentKubelet,
		Long:         componentKubelet,
		SilenceUsage: true,
		RunE:         func(cmd *cobra.Command, args []string) error { return nil },
	}

	// keep cleanFlagSet separate, so Cobra doesn't pollute it with the global flags
	kubeletFlags.AddFlags(cleanFlagSet)
	kubeletoptions.AddKubeletConfigFlags(cleanFlagSet, kubeletConfig)
	kubeletoptions.AddGlobalFlags(cleanFlagSet)
	cmd.Flags().AddFlagSet(cleanFlagSet)

	if err := cmd.ParseFlags(args); err != nil {
		logrus.Fatalf("%s failed to parse flags: %v", s.Name(), err)
	}

	s.kubeconfig = kubeletConfig
	s.kubeletflags = kubeletFlags

	logrus.Infof("Starting kubelet %s, args: %v", cfg.NodeIP, args)
	return nil
}

func (s *KubeletServer) Run(ctx context.Context, ready chan<- struct{}, stopped chan<- struct{}) error {

	defer close(stopped)
	// run readiness check
	go func() {
		healthcheckStatus := util.RetryInsecureHttpsGet("https://127.0.0.1:10250/healthz")
		if healthcheckStatus != 200 {
			logrus.Fatalf("%s failed to start", s.Name())
		}
		logrus.Infof("%s is ready", s.Name())
		close(ready)
	}()

	// construct a KubeletServer from kubeletFlags and kubeletConfig
	kubeletServer := &kubeletoptions.KubeletServer{
		KubeletFlags:         *s.kubeletflags,
		KubeletConfiguration: *s.kubeconfig,
	}

	kubeletDeps, err := kubelet.UnsecuredDependencies(kubeletServer, utilfeature.DefaultFeatureGate)
	if err != nil {
		logrus.Fatalf("Error in fetching depenedencies %v", err)
	}
	if err := kubelet.Run(ctx, kubeletServer, kubeletDeps, utilfeature.DefaultFeatureGate); err != nil {
		logrus.Fatalf("Kubelet failed to start %v", err)
	}
	return ctx.Err()
}

func StartKubeProxy(cfg *config.MicroshiftConfig) error {
	command := kubeproxy.NewProxyCommand()
	args := []string{
		"--config=" + cfg.DataDir + "/resources/kube-proxy/config/config.yaml",
		"--logtostderr=" + strconv.FormatBool(cfg.LogDir == "" || cfg.LogAlsotostderr),
		"--alsologtostderr=" + strconv.FormatBool(cfg.LogAlsotostderr),
		"--v=" + strconv.Itoa(cfg.LogVLevel),
		"--vmodule=" + cfg.LogVModule,
	}
	if cfg.LogDir != "" {
		args = append(args, "--log-file="+filepath.Join(cfg.LogDir, "kube-proxy.log"))
	}
	if err := command.ParseFlags(args); err != nil {
		logrus.Fatalf("failed to parse flags:%v", err)
	}
	logrus.Infof("starting kube-proxy, args: %v", args)

	go func() {
		command.Run(command, args)
		logrus.Fatalf("kube-proxy exited")
	}()

	return nil
}
