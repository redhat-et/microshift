/*
Copyright © 2021 MicroShift Contributors

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
package util

import (
	"context"
	"crypto/tls"
	"fmt"
	tcpnet "net"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/vishvananda/netlink"
	"k8s.io/apimachinery/pkg/util/net"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/klog/v2"
)

var previousGatewayIP string = ""

type routeStruct struct {
	// Name of interface
	Iface string

	// big-endian hex string
	Gateway string
}

// Remember whether we have successfully found the hard-coded nodeIP
// on this host.
var foundHardCodedNodeIP bool

func GetHostIP(nodeIP string) (string, error) {
	var hostIP string
	var err error

	if nodeIP != "" {
		if !foundHardCodedNodeIP {
			foundHardCodedNodeIP = true
			klog.Infof("trying to find configured nodeIP %q on host", nodeIP)
		}
		hostIP, err = selectIPFromHostInterface(nodeIP)
		if err != nil {
			foundHardCodedNodeIP = false
			return "", fmt.Errorf("failed to find the configured nodeIP %q on host: %v", nodeIP, err)
		}
		goto found
	}

	if ip, err := net.ChooseHostInterface(); err == nil {
		hostIP = ip.String()
	} else {
		klog.Infof("failed to get host IP by default route: %v", err)
		if hostIP, err = selectIPFromHostInterface(""); err != nil {
			return "", err
		}
	}

found:
	if hostIP != previousGatewayIP {
		previousGatewayIP = hostIP
		klog.V(2).Infof("host gateway IP address: %s", hostIP)
	}

	return hostIP, nil
}

func RetryInsecureGet(ctx context.Context, url string) int {
	status := 0
	err := wait.PollUntilContextTimeout(ctx, 5*time.Second, 120*time.Second, false, func(ctx context.Context) (bool, error) {
		c := http.Client{
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{
					InsecureSkipVerify: true, //nolint:gosec
				},
			},
		}
		resp, err := c.Get(url)
		if err != nil {
			return false, nil //nolint:nilerr
		}
		defer resp.Body.Close()
		status = resp.StatusCode
		return true, nil
	})

	if err != nil && err == context.DeadlineExceeded {
		klog.Warningf("Endpoint is not returning any status code")
	}

	return status
}

func RetryTCPConnection(ctx context.Context, host string, port string) bool {
	status := false
	err := wait.PollUntilContextTimeout(ctx, 5*time.Second, 120*time.Second, false, func(ctx context.Context) (bool, error) {
		timeout := 30 * time.Second
		_, err := tcpnet.DialTimeout("tcp", tcpnet.JoinHostPort(host, port), timeout)

		if err == nil {
			status = true
			return true, nil
		}
		return false, nil
	})
	if err != nil && err == context.DeadlineExceeded {
		klog.Warningf("Endpoint is not returning any status code")
	}
	return status
}

func AddToNoProxyEnv(additionalEntries ...string) error {
	entries := map[string]struct{}{}

	// put both the NO_PROXY and no_proxy elements in a map to avoid duplicates
	addNoProxyEnvVarEntries(entries, "NO_PROXY")
	addNoProxyEnvVarEntries(entries, "no_proxy")

	for _, entry := range additionalEntries {
		entries[entry] = struct{}{}
	}

	noProxyEnv := strings.Join(mapKeys(entries), ",")

	// unset the lower-case one, and keep only upper-case
	os.Unsetenv("no_proxy")
	if err := os.Setenv("NO_PROXY", noProxyEnv); err != nil {
		return fmt.Errorf("failed to update NO_PROXY: %w", err)
	}
	return nil
}

func mapKeys(entries map[string]struct{}) []string {
	keys := make([]string, 0, len(entries))
	for k := range entries {
		keys = append(keys, k)
	}

	// sort keys to avoid issues with map key ordering in go future versions on the unit-test side
	sort.Strings(keys)
	return keys
}

func addNoProxyEnvVarEntries(entries map[string]struct{}, envVar string) {
	noProxy := os.Getenv(envVar)

	if noProxy != "" {
		for _, entry := range strings.Split(noProxy, ",") {
			entries[strings.Trim(entry, " ")] = struct{}{}
		}
	}
}

func selectIPFromHostInterface(nodeIP string) (string, error) {
	ifaces, err := tcpnet.Interfaces()
	if err != nil {
		return "", err
	}

	// get list of interfaces
	for _, i := range ifaces {
		if i.Name == "br-ex" {
			continue
		}
		addrs, err := i.Addrs()
		if err != nil {
			klog.Warningf("failed to get IPs for interface %s: %v", i.Name, err)
			continue
		}

		for _, addr := range addrs {
			ip, _, err := tcpnet.ParseCIDR(addr.String())
			if err != nil {
				return "", fmt.Errorf("unable to parse CIDR for interface %q: %s", i.Name, err)
			}
			if ip.IsLoopback() {
				continue
			}
			if nodeIP != "" && nodeIP != ip.String() {
				continue
			}
			return ip.String(), nil
		}
	}
	return "", fmt.Errorf("no interface with valid address found on host")
}

// ContainIPANetwork - will check if given IP address contained within list of networks
func ContainIPANetwork(ip tcpnet.IP, networks []string) bool {
	for _, netStr := range networks {
		_, netA, err := tcpnet.ParseCIDR(netStr)
		if err != nil {
			klog.Warningf("Could not parse CIDR %s, err: %v", netA, err)
			return false
		}
		if netA.Contains(ip) {
			return true
		}
	}
	return false
}

func GetHostIPv6(ipHint string) (string, error) {
	handle, err := netlink.NewHandle()
	if err != nil {
		return "", err
	}
	// Start by looking for the default route and using the dev
	// address.
	routeList, err := handle.RouteList(nil, netlink.FAMILY_V6)
	if err != nil {
		return "", err
	}
	defaultRouteLinkIndex := -1
	for _, route := range routeList {
		if route.Dst == nil {
			defaultRouteLinkIndex = route.LinkIndex
			break
		}
	}

	if defaultRouteLinkIndex != -1 {
		link, err := handle.LinkByIndex(defaultRouteLinkIndex)
		if err != nil {
			return "", err
		}
		addrList, err := handle.AddrList(link, netlink.FAMILY_V6)
		if err != nil {
			return "", err
		}
		for _, addr := range addrList {
			if ipHint != "" && ipHint != addr.IP.String() {
				continue
			}
			return addr.IP.String(), nil
		}
	}

	// If there is no default route then pick the first ipv6
	// address that fits.
	addrList, err := handle.AddrList(nil, netlink.FAMILY_V6)
	if err != nil {
		return "", err
	}
	for _, addr := range addrList {
		ip, _, err := tcpnet.ParseCIDR(addr.String())
		if err != nil {
			return "", fmt.Errorf("unable to parse CIDR from address %q: %s", addr.String(), err)
		}
		if ip.IsLoopback() || ip.IsLinkLocalMulticast() {
			continue
		}
		if ipHint != "" && ipHint != ip.String() {
			continue
		}
		return ip.String(), nil
	}

	return "", fmt.Errorf("unable to find host IPv6 address")
}

// Find the Default route Interface based on ipv4 or ipv6 routes.
func FindDefaultRouteIface() (iface *tcpnet.Interface, err error) {

	// first try IPv4
	parsedStruct, err := findDefaultRouteForFamily(netlink.FAMILY_V4)
	if err != nil {

		// then try IPv6
		parsedStruct, err = findDefaultRouteForFamily(netlink.FAMILY_V6)
		if err != nil {
			return nil, err
		}
	}

	iface, err = tcpnet.InterfaceByName(parsedStruct.Iface)
	if err != nil {
		return nil, err
	}

	return iface, nil
}

func findDefaultRouteForFamily(family int) (routeStruct, error) {
	handle, err := netlink.NewHandle()
	if err != nil {
		return routeStruct{}, err
	}

	routeList, err := handle.RouteList(nil, family)
	if err != nil {
		return routeStruct{}, err
	}

	for _, route := range routeList {

		//  for Default route the Destination should be nil (0)
		if route.Dst == nil {
			link, err := handle.LinkByIndex(route.LinkIndex)
			if err != nil {
				return routeStruct{}, err
			}
			return routeStruct{
				Iface:   link.Attrs().Name,
				Gateway: route.Gw.String(),
			}, nil

		}

	}
	return routeStruct{}, fmt.Errorf("no default gateway found")
}
