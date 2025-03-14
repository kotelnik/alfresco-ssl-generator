#! /bin/bash

set -o errexit
set -o pipefail
set -o nounset

# This script generates certificates for Repository and SOLR TLS/SSL Mutual Auth Communication:
#
# * CA Entity to issue all required certificates (alias alfresco.ca)
# * Server Certificate for Alfresco (alias ssl.repo)
# * Server Certificate for SOLR (alias ssl.repo.client)
#
# "openssl.cnf" file is provided for CA Configuration.
#
# Once this script has been executed successfully, following resources are generated in ${KEYSTORES_DIR} folder for "classic" Alfresco format:
#
# .
# ├── alfresco
# │   ├── keystore
# │   ├── keystore-passwords.properties
# │   ├── ssl-keystore-passwords.properties
# │   ├── ssl-truststore-passwords.properties
# │   ├── ssl.keystore
# │   └── ssl.truststore
# ├── client
# │   └── browser.p12
# ├── solr
# │   ├── ssl-keystore-passwords.properties
# │   ├── ssl-truststore-passwords.properties
# │   ├── ssl.repo.client.keystore
# │   └── ssl.repo.client.truststore
# └── zeppelin
#     ├── ssl.repo.client.keystore
#     └── ssl.repo.client.truststore
#
# When using "current" Alfresco format (available from ACS 7.0), following resources are generated in ${KEYSTORES_DIR}
# .
# ├── alfresco
# │   ├── keystore
# │   ├── ssl.keystore
# │   └── ssl.truststore
# ├── client
# │   └── browser.p12
# ├── solr
# │   ├── ssl-repo-client.keystore
# │   └── ssl-repo-client.truststore
# └── zeppelin
#     ├── ssl-repo-client.keystore
#     └── ssl-repo-client.truststore
#
# "alfresco" files must be copied to "alfresco/keystore" folder
# "solr" files must be copied to "solr6/keystore"
# "zeppelin" files must be copied to "zeppelin/keystore"
# "client" files can be used from a browser to access the server using HTTPS in port 8443

# PARAMETERS

# Version of Alfresco: enterprise, community
ALFRESCO_VERSION=enterprise

# Using "current" format by default (only available from ACS 7.0+)
ALFRESCO_FORMAT=current

# Distinguished name of the CA
CA_DNAME="/C=GB/ST=UK/L=Maidenhead/O=Alfresco Software Ltd./OU=Unknown/CN=Custom Alfresco CA"
# Distinguished name of the Server Certificate for Alfresco
REPO_CERT_DNAME="/C=GB/ST=UK/L=Maidenhead/O=Alfresco Software Ltd./OU=Unknown/CN=Custom Alfresco Repository"
# Distinguished name of the Server Certificate for SOLR
SOLR_CLIENT_CERT_DNAME="/C=GB/ST=UK/L=Maidenhead/O=Alfresco Software Ltd./OU=Unknown/CN=Custom Alfresco Repository Client"
# Distinguished name of the Browser Certificate for SOLR
BROWSER_CLIENT_CERT_DNAME="/C=GB/ST=UK/L=Maidenhead/O=Alfresco Software Ltd./OU=Unknown/CN=Custom Browser Client"

# Alfresco and SOLR server names, to be used as Alternative Name in the certificates
CA_SERVER_NAME=localhost
ALFRESCO_SERVER_NAME=localhost
SOLR_SERVER_NAME=localhost

# RSA key length (1024, 2048, 4096)
KEY_SIZE=2048

# Keystore format (PKCS12, JKS, JCEKS)
KEYSTORE_TYPE=JCEKS
# Truststore format (JKS, JCEKS)
TRUSTSTORE_TYPE=JCEKS

# Default password for every keystore and private key
KEYSTORE_PASS=keystore
# Default password for every truststore
TRUSTSTORE_PASS=truststore

# Encryption secret key passwords
ENC_STORE_PASS=password
ENC_METADATA_PASS=password

# Folder where keystores, truststores and cerfiticates are generated
KEYSTORES_DIR=keystores
ALFRESCO_KEYSTORES_DIR=keystores/alfresco
SOLR_KEYSTORES_DIR=keystores/solr
ZEPPELIN_KEYSTORES_DIR=keystores/zeppelin
CLIENT_KEYSTORES_DIR=keystores/client
CERTIFICATES_DIR=certificates

# SCRIPT
# Generates every keystore, trustore and certificate required for Alfresco SSL configuration
function generate {

  # Encryption keystore format: PKCS12 (default for "current"), JCEKS (default for "classic")
  if [ "$ALFRESCO_FORMAT" == "current" ]; then
    ENC_STORE_TYPE=PKCS12
  else
    ENC_STORE_TYPE=JCEKS
  fi

  # Key algorithm: AES (default for "current"), DESede (default for "classic")
  if [ "$ALFRESCO_FORMAT" == "current" ]; then
    ENC_KEY_ALG="-keyalg AES -keysize 256"
  else
    ENC_KEY_ALG="-keyalg DESede"
  fi

  # If target folder for Keystores is not empty, skip generation
  if [ "$(ls -A $KEYSTORES_DIR)" ]; then
    echo "Keystores folder is not empty, skipping generation process..."
    exit 1
  fi

  # Remove previous working directories and certificates
  if [ -d ca ]; then
      rm -rf ca/*
  fi

  # Create folders for truststores, keystores and certificates
  if [ ! -d "$KEYSTORES_DIR" ]; then
    mkdir -p $KEYSTORES_DIR
  else
    rm -rf $KEYSTORES_DIR/*
  fi

  if [ ! -d "$ALFRESCO_KEYSTORES_DIR" ]; then
    mkdir -p $ALFRESCO_KEYSTORES_DIR
  else
    rm -rf $ALFRESCO_KEYSTORES_DIR/*
  fi

  if [ ! -d "$SOLR_KEYSTORES_DIR" ]; then
    mkdir -p $SOLR_KEYSTORES_DIR
  else
    rm -rf $SOLR_KEYSTORES_DIR/*
  fi

  if [ "$ALFRESCO_VERSION" = "enterprise" ]; then
    if [ ! -d "$ZEPPELIN_KEYSTORES_DIR" ]; then
      mkdir -p $ZEPPELIN_KEYSTORES_DIR
    else
      rm -rf $ZEPPELIN_KEYSTORES_DIR/*
    fi
  fi

  if [ ! -d "$CLIENT_KEYSTORES_DIR" ]; then
    mkdir -p $CLIENT_KEYSTORES_DIR
  else
    rm -rf $CLIENT_KEYSTORES_DIR/*
  fi

  if [ ! -d "$CERTIFICATES_DIR" ]; then
    mkdir -p $CERTIFICATES_DIR
  else
    rm -rf $CERTIFICATES_DIR/*
  fi

  #
  # CA
  #

  # Generate a new CA Entity
  if [ ! -d ca ]; then
    mkdir ca
  fi

  mkdir ca/certs ca/crl ca/newcerts ca/private
  chmod 700 ca/private
  touch ca/index.txt
  echo 1000 > ca/serial

  openssl genrsa -aes256 -passout pass:$KEYSTORE_PASS -out ca/private/ca.key.pem $KEY_SIZE
  chmod 400 ca/private/ca.key.pem

  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/DNS.1.*/DNS.1 = $CA_SERVER_NAME/" openssl.cnf;
  else
    sed -i "s/DNS.1.*/DNS.1 = $CA_SERVER_NAME/" openssl.cnf;
  fi

  openssl req -config openssl.cnf \
        -key ca/private/ca.key.pem \
        -new -x509 -days 7300 -sha256 -extensions v3_ca \
        -out ca/certs/ca.cert.pem \
        -subj "$CA_DNAME" \
        -passin pass:$KEYSTORE_PASS
  chmod 444 ca/certs/ca.cert.pem

  # Generate Server Certificate for Alfresco (issued by just generated CA)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/DNS.1.*/DNS.1 = $ALFRESCO_SERVER_NAME/" openssl.cnf;
  else
    sed -i "s/DNS.1.*/DNS.1 = $ALFRESCO_SERVER_NAME/" openssl.cnf;
  fi
  openssl req -newkey rsa:$KEY_SIZE -nodes -out $CERTIFICATES_DIR/repository.csr -keyout $CERTIFICATES_DIR/repository.key -subj "$REPO_CERT_DNAME"

  openssl ca -config openssl.cnf -extensions clientServer_cert -passin pass:$KEYSTORE_PASS -batch -notext \
  -in $CERTIFICATES_DIR/repository.csr -out $CERTIFICATES_DIR/repository.cer

  openssl pkcs12 -export -out $CERTIFICATES_DIR/repository.p12 -inkey $CERTIFICATES_DIR/repository.key \
  -in $CERTIFICATES_DIR/repository.cer -password pass:$KEYSTORE_PASS -certfile ca/certs/ca.cert.pem

  # Server Certificate for SOLR (issued by just generated CA)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/DNS.1.*/DNS.1 = $SOLR_SERVER_NAME/" openssl.cnf;
  else
    sed -i "s/DNS.1.*/DNS.1 = $SOLR_SERVER_NAME/" openssl.cnf;
  fi
  openssl req -newkey rsa:$KEY_SIZE -nodes -out $CERTIFICATES_DIR/solr.csr -keyout $CERTIFICATES_DIR/solr.key -subj "$SOLR_CLIENT_CERT_DNAME"

  openssl ca -config openssl.cnf -extensions clientServer_cert -passin pass:$KEYSTORE_PASS -batch -notext \
  -in $CERTIFICATES_DIR/solr.csr -out $CERTIFICATES_DIR/solr.cer

  openssl pkcs12 -export -out $CERTIFICATES_DIR/solr.p12 -inkey $CERTIFICATES_DIR/solr.key \
  -in $CERTIFICATES_DIR/solr.cer -password pass:$KEYSTORE_PASS -certfile ca/certs/ca.cert.pem

  # Client Certificate for SOLR (issued by just generated CA)
  openssl req -newkey rsa:$KEY_SIZE -nodes -out $CERTIFICATES_DIR/browser.csr -keyout $CERTIFICATES_DIR/browser.key \
  -subj "$BROWSER_CLIENT_CERT_DNAME"

  openssl ca -config openssl.cnf -extensions client_cert -passin pass:$KEYSTORE_PASS -batch -notext \
  -in $CERTIFICATES_DIR/browser.csr -out $CERTIFICATES_DIR/browser.cer

  openssl pkcs12 -export -out $CERTIFICATES_DIR/browser.p12 -inkey $CERTIFICATES_DIR/browser.key \
  -in $CERTIFICATES_DIR/browser.cer -password pass:$KEYSTORE_PASS -certfile ca/certs/ca.cert.pem

  #
  # SOLR
  #

  # Include CA and Alfresco certificates in SOLR Truststore
  keytool -import -trustcacerts -noprompt -alias alfresco.ca -file ca/certs/ca.cert.pem \
  -keystore ${SOLR_KEYSTORES_DIR}/ssl.repo.client.truststore -storetype $TRUSTSTORE_TYPE -storepass $TRUSTSTORE_PASS

  keytool -importcert -noprompt -alias ssl.repo -file $CERTIFICATES_DIR/repository.cer \
  -keystore ${SOLR_KEYSTORES_DIR}/ssl.repo.client.truststore -storetype $TRUSTSTORE_TYPE -storepass $TRUSTSTORE_PASS

  keytool -importcert -noprompt -alias ssl.repo.client -file $CERTIFICATES_DIR/solr.cer \
  -keystore ${SOLR_KEYSTORES_DIR}/ssl.repo.client.truststore -storetype $TRUSTSTORE_TYPE -storepass $TRUSTSTORE_PASS

  # Create SOLR TrustStore password file
  echo "aliases=alfresco.ca,ssl.repo,ssl.repo.client" >> ${SOLR_KEYSTORES_DIR}/ssl-truststore-passwords.properties
  echo "keystore.password=$TRUSTSTORE_PASS" >> ${SOLR_KEYSTORES_DIR}/ssl-truststore-passwords.properties
  echo "alfresco.ca.password=$TRUSTSTORE_PASS" >> ${SOLR_KEYSTORES_DIR}/ssl-truststore-passwords.properties
  echo "ssl.repo.password=$TRUSTSTORE_PASS" >> ${SOLR_KEYSTORES_DIR}/ssl-truststore-passwords.properties
  echo "ssl.repo.client.password=$TRUSTSTORE_PASS" >> ${SOLR_KEYSTORES_DIR}/ssl-truststore-passwords.properties

  # Include SOLR Certificate in SOLR Keystore
  # Also adding CA Certificate for historical reasons
  keytool -importkeystore \
  -srckeystore $CERTIFICATES_DIR/solr.p12 -destkeystore ${SOLR_KEYSTORES_DIR}/ssl.repo.client.keystore \
  -srcstoretype PKCS12 -deststoretype $KEYSTORE_TYPE \
  -srcstorepass $KEYSTORE_PASS -deststorepass $KEYSTORE_PASS \
  -srcalias 1 -destalias ssl.repo.client \
  -srckeypass $KEYSTORE_PASS -destkeypass $KEYSTORE_PASS \
  -noprompt

  keytool -importcert -noprompt -alias ssl.alfresco.ca -file ca/certs/ca.cert.pem \
  -keystore ${SOLR_KEYSTORES_DIR}/ssl.repo.client.keystore -storetype $KEYSTORE_TYPE -storepass $KEYSTORE_PASS

  # Create SOLR Keystore password file
  echo "aliases=ssl.alfresco.ca,ssl.repo.client" >> ${SOLR_KEYSTORES_DIR}/ssl-keystore-passwords.properties
  echo "keystore.password=$KEYSTORE_PASS" >> ${SOLR_KEYSTORES_DIR}/ssl-keystore-passwords.properties
  echo "ssl.repo.client.password=$KEYSTORE_PASS" >> ${SOLR_KEYSTORES_DIR}/ssl-keystore-passwords.properties
  echo "ssl.alfresco.ca.password=$KEYSTORE_PASS" >> ${SOLR_KEYSTORES_DIR}/ssl-keystore-passwords.properties


  #
  # Zeppelin (SOLR JDBC)
  #

  # Copy ZEPPELIN stores
  if [ "$ALFRESCO_VERSION" = "enterprise" ]; then

    cp ${SOLR_KEYSTORES_DIR}/ssl.repo.client.keystore ${ZEPPELIN_KEYSTORES_DIR}/ssl.repo.client.keystore
    cp ${SOLR_KEYSTORES_DIR}/ssl.repo.client.truststore ${ZEPPELIN_KEYSTORES_DIR}/ssl.repo.client.truststore

  fi

  #
  # ALFRESCO
  #

  # Include CA and SOLR certificates in Alfresco Truststore
  keytool -import -trustcacerts -noprompt -alias alfresco.ca -file ca/certs/ca.cert.pem \
  -keystore ${ALFRESCO_KEYSTORES_DIR}/ssl.truststore -storetype $TRUSTSTORE_TYPE -storepass $TRUSTSTORE_PASS

  keytool -importcert -noprompt -alias ssl.repo.client -file $CERTIFICATES_DIR/solr.cer \
  -keystore ${ALFRESCO_KEYSTORES_DIR}/ssl.truststore -storetype $TRUSTSTORE_TYPE -storepass $TRUSTSTORE_PASS

  # Create Alfresco TrustStore password file
  echo "aliases=alfresco.ca,ssl.repo.client" >> ${ALFRESCO_KEYSTORES_DIR}/ssl-truststore-passwords.properties
  echo "keystore.password=$TRUSTSTORE_PASS" >> ${ALFRESCO_KEYSTORES_DIR}/ssl-truststore-passwords.properties
  echo "alfresco.ca.password=$TRUSTSTORE_PASS" >> ${ALFRESCO_KEYSTORES_DIR}/ssl-truststore-passwords.properties
  echo "ssl.repo.client=$TRUSTSTORE_PASS" >> ${ALFRESCO_KEYSTORES_DIR}/ssl-truststore-passwords.properties

  # Include Alfresco Certificate in Alfresco Keystore
  # Also adding CA Certificate for historical reasons
  keytool -importkeystore \
  -srckeystore $CERTIFICATES_DIR/repository.p12 -destkeystore ${ALFRESCO_KEYSTORES_DIR}/ssl.keystore \
  -srcstoretype PKCS12 -deststoretype $KEYSTORE_TYPE \
  -srcstorepass $KEYSTORE_PASS -deststorepass $KEYSTORE_PASS \
  -srcalias 1 -destalias ssl.repo \
  -srckeypass $KEYSTORE_PASS -destkeypass $KEYSTORE_PASS \
  -noprompt

  keytool -importcert -noprompt -alias ssl.alfresco.ca -file ca/certs/ca.cert.pem \
  -keystore ${ALFRESCO_KEYSTORES_DIR}/ssl.keystore -storetype $KEYSTORE_TYPE -storepass $KEYSTORE_PASS

  # Create Alfresco Keystore password file
  echo "aliases=ssl.alfresco.ca,ssl.repo" >> ${ALFRESCO_KEYSTORES_DIR}/ssl-keystore-passwords.properties
  echo "keystore.password=$KEYSTORE_PASS" >> ${ALFRESCO_KEYSTORES_DIR}/ssl-keystore-passwords.properties
  echo "ssl.repo.password=$KEYSTORE_PASS" >> ${ALFRESCO_KEYSTORES_DIR}/ssl-keystore-passwords.properties
  echo "ssl.alfresco.ca.password=$KEYSTORE_PASS" >> ${ALFRESCO_KEYSTORES_DIR}/ssl-keystore-passwords.properties

  # Generate Encryption Secret Key
  keytool -genseckey -alias metadata -keypass $ENC_METADATA_PASS -storepass $ENC_STORE_PASS -keystore ${ALFRESCO_KEYSTORES_DIR}/keystore \
  -storetype $ENC_STORE_TYPE $ENC_KEY_ALG

  # Create Alfresco Encryption password file
  echo "aliases=metadata" >> ${ALFRESCO_KEYSTORES_DIR}/keystore-passwords.properties
  echo "keystore.password=$ENC_STORE_PASS" >> ${ALFRESCO_KEYSTORES_DIR}/keystore-passwords.properties
  echo "metadata.keyData=" >> ${ALFRESCO_KEYSTORES_DIR}/keystore-passwords.properties
  echo "metadata.algorithm=DESede" >> ${ALFRESCO_KEYSTORES_DIR}/keystore-passwords.properties
  echo "metadata.password=$ENC_METADATA_PASS" >> ${ALFRESCO_KEYSTORES_DIR}/keystore-passwords.properties


  #
  # CLIENT
  #

  # Create client (browser) certificate
  cp $CERTIFICATES_DIR/browser.p12 $CLIENT_KEYSTORES_DIR/browser.p12

  #
  # Renaming files for current Alfresco Format
  #
  if [ "$ALFRESCO_FORMAT" = "current" ]; then
    rm ${SOLR_KEYSTORES_DIR}/ssl-truststore-passwords.properties
    rm ${SOLR_KEYSTORES_DIR}/ssl-keystore-passwords.properties
    rm ${ALFRESCO_KEYSTORES_DIR}/ssl-truststore-passwords.properties
    rm ${ALFRESCO_KEYSTORES_DIR}/ssl-keystore-passwords.properties
    rm ${ALFRESCO_KEYSTORES_DIR}/keystore-passwords.properties
    mv ${SOLR_KEYSTORES_DIR}/ssl.repo.client.truststore ${SOLR_KEYSTORES_DIR}/ssl-repo-client.truststore
    mv ${SOLR_KEYSTORES_DIR}/ssl.repo.client.keystore ${SOLR_KEYSTORES_DIR}/ssl-repo-client.keystore
    if [ "$ALFRESCO_VERSION" = "enterprise" ]; then
      mv ${ZEPPELIN_KEYSTORES_DIR}/ssl.repo.client.keystore ${ZEPPELIN_KEYSTORES_DIR}/ssl-repo-client.keystore
      mv ${ZEPPELIN_KEYSTORES_DIR}/ssl.repo.client.truststore ${ZEPPELIN_KEYSTORES_DIR}/ssl-repo-client.truststore
    fi
  fi

}

# EXECUTION
# Parse params from command line
while test $# -gt 0
do
    case "$1" in
        # community, enterprise
        -alfrescoversion)
            ALFRESCO_VERSION=$2
            shift
        ;;
        # 1024, 2048, 4096, ...
        -keysize)
            KEY_SIZE=$2
            shift
        ;;
        # PKCS12, JKS, JCEKS
        -keystoretype)
            KEYSTORE_TYPE=$2
            shift
        ;;
        # JKS, JCEKS
        -truststoretype)
            TRUSTSTORE_TYPE=$2
            shift
        ;;
        # Password for keystores and private keys
        -keystorepass)
            KEYSTORE_PASS=$2
            shift
        ;;
        # Password for truststores
        -truststorepass)
            TRUSTSTORE_PASS=$2
            shift
        ;;
        # Password for encryption keystore
        -encstorepass)
            ENC_STORE_PASS=$2
            shift
        ;;
        # Password for encryption metadata
        -encmetadatapass)
            ENC_METADATA_PASS=$2
            shift
        ;;
        # DName for CA issuing the certificates
        -cacertdname)
            CA_DNAME="$2"
            shift
        ;;
        # DName for Repository certificate
        -repocertdname)
            REPO_CERT_DNAME="$2"
            shift
        ;;
        # DName for SOLR certificate
        -solrcertdname)
            SOLR_CLIENT_CERT_DNAME="$2"
            shift
        ;;
        # DName for Browser certificate
        -browsercertdname)
            BROWSER_CLIENT_CERT_DNAME="$2"
            shift
        ;;
        # DNS name for CA Server
        -caservername)
            CA_SERVER_NAME="$2"
            shift
        ;;
        # DNS name for Alfresco Server
        -alfrescoservername)
            ALFRESCO_SERVER_NAME="$2"
            shift
        ;;
        # DNS name for SOLR Server
        -solrservername)
            SOLR_SERVER_NAME="$2"
            shift
        ;;
        # Alfresco Format: "classic" / "current" is supported only from 7.0
        -alfrescoformat)
            ALFRESCO_FORMAT="$2"
            shift
        ;;
        *)
            echo "An invalid parameter was received: $1"
            echo "Allowed parameters:"
            echo "  -alfrescoversion"
            echo "  -keysize"
            echo "  -keystoretype"
            echo "  -keystorepass"
            echo "  -truststoretype"
            echo "  -truststorepass"
            echo "  -encstorepass"
            echo "  -encmetadatapass"
            echo "  -cacertdname"
            echo "  -repocertdname"
            echo "  -solrcertdname"
            echo "  -browsercertdname"
            echo "  -caservername"
            echo "  -alfrescoservername"
            echo "  -solrservername"
            echo "  -alfrescoformat"
            exit 1
        ;;
    esac
    shift
done

# Generating keystores, truststores and certificates
generate
