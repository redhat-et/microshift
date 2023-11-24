// Code generated by client-gen. DO NOT EDIT.

package v1

import (
	"net/http"

	v1 "github.com/openshift/api/user/v1"
	"github.com/openshift/client-go/user/clientset/versioned/scheme"
	rest "k8s.io/client-go/rest"
)

type UserV1Interface interface {
	RESTClient() rest.Interface
	GroupsGetter
	IdentitiesGetter
	UsersGetter
	UserIdentityMappingsGetter
}

// UserV1Client is used to interact with features provided by the user.openshift.io group.
type UserV1Client struct {
	restClient rest.Interface
}

func (c *UserV1Client) Groups() GroupInterface {
	return newGroups(c)
}

func (c *UserV1Client) Identities() IdentityInterface {
	return newIdentities(c)
}

func (c *UserV1Client) Users() UserInterface {
	return newUsers(c)
}

func (c *UserV1Client) UserIdentityMappings() UserIdentityMappingInterface {
	return newUserIdentityMappings(c)
}

// NewForConfig creates a new UserV1Client for the given config.
// NewForConfig is equivalent to NewForConfigAndClient(c, httpClient),
// where httpClient was generated with rest.HTTPClientFor(c).
func NewForConfig(c *rest.Config) (*UserV1Client, error) {
	config := *c
	if err := setConfigDefaults(&config); err != nil {
		return nil, err
	}
	httpClient, err := rest.HTTPClientFor(&config)
	if err != nil {
		return nil, err
	}
	return NewForConfigAndClient(&config, httpClient)
}

// NewForConfigAndClient creates a new UserV1Client for the given config and http client.
// Note the http client provided takes precedence over the configured transport values.
func NewForConfigAndClient(c *rest.Config, h *http.Client) (*UserV1Client, error) {
	config := *c
	if err := setConfigDefaults(&config); err != nil {
		return nil, err
	}
	client, err := rest.RESTClientForConfigAndClient(&config, h)
	if err != nil {
		return nil, err
	}
	return &UserV1Client{client}, nil
}

// NewForConfigOrDie creates a new UserV1Client for the given config and
// panics if there is an error in the config.
func NewForConfigOrDie(c *rest.Config) *UserV1Client {
	client, err := NewForConfig(c)
	if err != nil {
		panic(err)
	}
	return client
}

// New creates a new UserV1Client for the given RESTClient.
func New(c rest.Interface) *UserV1Client {
	return &UserV1Client{c}
}

func setConfigDefaults(config *rest.Config) error {
	gv := v1.SchemeGroupVersion
	config.GroupVersion = &gv
	config.APIPath = "/apis"
	config.NegotiatedSerializer = scheme.Codecs.WithoutConversion()

	if config.UserAgent == "" {
		config.UserAgent = rest.DefaultKubernetesUserAgent()
	}

	return nil
}

// RESTClient returns a RESTClient that is used to communicate
// with API server by this client implementation.
func (c *UserV1Client) RESTClient() rest.Interface {
	if c == nil {
		return nil
	}
	return c.restClient
}
